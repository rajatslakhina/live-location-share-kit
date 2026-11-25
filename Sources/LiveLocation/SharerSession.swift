import Foundation

/// The sharer's path to the relay. `LocationRelay` conforms directly (in-process, as in the demo);
/// a production client would implement it over HTTPS.
///
/// **Error contract.** `revoke` and `stop` must be idempotent: for a share or viewer the relay no longer
/// knows, either succeed or throw `RelayError.unknownShare` (an HTTPS client maps its 404 to that); the
/// session treats both as acknowledged. `addViewer` reports a refusal as a `RelayError`. Any other error
/// is treated as a transport failure: the call stays pending and `flushOutbox` retries it.
public protocol RelayUplink: Sendable {
    /// The relay's presence TTL. The session reads its heartbeat interval from here, so the two can never
    /// disagree.
    var presenceTTL: Millis { get }
    func upload(_ copies: [SealedPoint]) async throws -> PublishReceipt
    func revoke(_ viewer: ViewerID, from share: ShareID) async throws
    func addViewer(_ viewer: ViewerID, to share: ShareID) async throws
    func stop(_ share: ShareID) async throws
}

extension LocationRelay: RelayUplink {
    public nonisolated var presenceTTL: Millis { configuration.presenceTTL }
    public func upload(_ copies: [SealedPoint]) async throws -> PublishReceipt { publish(copies) }
    public func stop(_ share: ShareID) async throws { stopShare(share) }
}

public enum SessionError: Error, Equatable, Sendable {
    /// The app's capability manifest does not declare `.liveLocationSharing`, so the session refuses
    /// to exist. This is what ties runtime behaviour to the age-rating declaration (see `AgeRatingGate`).
    case capabilityNotDeclared
    /// The share already ended (stopped, or gone at the relay).
    case shareEnded
}

public enum IngestOutcome: Sendable, Hashable {
    case published(PublishReason, sequence: UInt64, receipt: PublishReceipt)
    case suppressed(SuppressReason)
    /// Sealed and uploaded, but the relay accepted no copy (all stale, not a recipient, or future).
    case rejected(sequence: UInt64, receipt: PublishReceipt)
    /// Sealed, but the uplink failed, and the batch is now held in the one-slot, latest-wins outbox (or
    /// superseded there by a newer held batch). If a newer batch was already uploaded, or every viewer it
    /// was for was revoked meanwhile, nothing is held and the result is `.idle` instead.
    case heldOffline(sequence: UInt64)
    /// Nothing to send (no recipients left, or no prior fix to heartbeat), or a failed batch that nothing
    /// needs any more (see `heldOffline`).
    case idle
    /// The share is over (stopped locally, or the relay says it expired/was stopped). Nothing more is
    /// sealed or uploaded.
    case ended
}

public struct SessionCounters: Sendable, Hashable {
    public internal(set) var fixesSeen = 0
    /// Batches sealed (each is one point, one copy per viewer).
    public internal(set) var sealed = 0
    /// Batches the relay accepted for at least one viewer (including ones flushed from the offline outbox).
    public internal(set) var uploaded = 0
    public internal(set) var heartbeats = 0
    public internal(set) var suppressed: [SuppressReason: Int] = [:]
    /// Batches whose upload failed (each returned `.heldOffline`; only the newest is kept).
    public internal(set) var heldOffline = 0
    public init() {}
}

/// Sharer-side coordinator: `PublishPolicy` → `PublishGate` → battery `TokenBucket` → `PerViewerSealer`
/// → `RelayUplink`, with a latest-wins offline outbox.
///
/// **Reentrancy.** Everything that must be atomic — the gate decision, the budget token, the sequence
/// number, the sealing and the gate commit — happens *before* the upload `await` in `ingest`/`tick`. Two
/// concurrent `ingest` calls therefore always get distinct, increasing sequence numbers, and if their
/// uploads land out of order the relay's monotonic check drops the older one. After the `await`, the
/// outbox is only ever replaced by a *newer* sequence, and only with copies for current recipients.
///
/// **Relaunch.** iOS kills background apps mid-share. To resume, persist `sealer.privateKeyRaw` (Keychain)
/// and restore with `PerViewerSealer(shareID:privateKeyRaw:)`. Sequences need no persistence by default:
/// they follow `epochSequence(now)` = wall-clock ms × 2¹⁶, so a relaunched session always starts above
/// everything the previous one sent (unless the device clock is set back). The app must also persist the
/// viewer list (IDs + public keys), `unacknowledgedRevocations`, `unacknowledgedAdds` and
/// `stopUnacknowledged`, re-apply them after relaunch, and check `refusedAdds` after each `flushOutbox`. The battery budget and the publish gate start
/// fresh after a relaunch.
public actor SharerSession {
    public let shareID: ShareID
    private var sealer: PerViewerSealer
    private let uplink: any RelayUplink
    private let clock: any LiveClock
    public let presenceTTL: Millis

    private var gate: PublishGate
    private var budget: TokenBucket
    private var nextSequence: UInt64
    private var outbox: [SealedPoint] = []
    private var outboxSequence: UInt64 = 0
    private var outboxReason: PublishReason = .moved
    /// One relay intent for a viewer. `epoch` is unique per `addViewer`/`revoke` call, so a refusal can be
    /// matched to the exact intent it answers, not merely to an equal-looking later one.
    private struct Intent: Equatable { let onShare: Bool; let epoch: UInt64 }
    /// Pending relay intents only. Entries are removed once the relay acknowledges (or finally refuses),
    /// so this holds only unfinished work.
    private var desiredOnRelay: [ViewerID: Intent] = [:]
    private var intentEpoch: UInt64 = 0
    private var reconciling: Set<ViewerID> = []
    /// Default mode: sequences follow the wall clock (see `send`). Off when the caller passes
    /// `startingSequence`, which gives a plain counter (tests, or apps that persist sequences).
    private let clockDrivenSequence: Bool
    private var pendingRelayStop = false
    public private(set) var isEnded = false
    /// Adds the relay finally refused, with its reason. A refused viewer is also removed locally. Filled
    /// whichever call met the refusal — including a `flushOutbox` retry, which has no caller to throw to —
    /// and cleared for a viewer when `addViewer` is called for them again.
    public private(set) var refusedAdds: [ViewerID: RelayError] = [:]
    public private(set) var counters = SessionCounters()
    public private(set) var lastCadence: PublishCadence?

    /// - Parameters:
    ///   - discretionaryBudget: movement publishes allowed per session as a burst, refilling one per
    ///     `budgetRefill`. Heartbeats never spend it — presence must not die because the user walked a lot.
    ///   - startingSequence: defaults to `epochSequence(clock.now())`; pass an explicit value only in tests
    ///     or if you persist sequences yourself.
    public init(shareID: ShareID, manifest: CapabilityManifest, sealer: PerViewerSealer,
                uplink: any RelayUplink, clock: any LiveClock,
                discretionaryBudget: Int = 120, budgetRefill: Millis = .seconds(30),
                maxAccuracyMeters: Double = 200, startingSequence: UInt64? = nil) throws {
        guard manifest.capabilities.contains(.liveLocationSharing) else { throw SessionError.capabilityNotDeclared }
        self.shareID = shareID
        self.sealer = sealer
        self.uplink = uplink
        self.clock = clock
        self.presenceTTL = max(PublishPolicy.minimumPresenceTTL, uplink.presenceTTL)
        self.gate = PublishGate(maxAccuracyMeters: maxAccuracyMeters)
        self.budget = TokenBucket(capacity: discretionaryBudget, refillEvery: budgetRefill, now: clock.now())
        self.nextSequence = max(1, startingSequence ?? Self.epochSequence(clock.now()))
        self.clockDrivenSequence = startingSequence == nil
    }

    /// Wall-clock milliseconds × 65,536. Strictly above any sequence a previous session on the same share
    /// could have reached unless it published more than 65,536 points per millisecond since it started.
    public static func epochSequence(_ now: Instant) -> UInt64 {
        let ms = UInt64(clamping: max(0, now.millis))
        let (shifted, overflow) = ms.multipliedReportingOverflow(by: 1 << 16)
        // Saturate (never wrap) so the sequence stays monotonic in time; a real clock cannot get here.
        return overflow ? UInt64.max : shifted
    }

    public var recipients: [ViewerID] { sealer.recipients }
    public var budgetRemaining: Int { budget.tokens }
    /// The sequence the next batch will carry.
    public var upcomingSequence: UInt64 { nextSequence }
    /// Who the held offline batch is addressed to (empty when nothing is held).
    public var heldBatchRecipients: [ViewerID] { outbox.map(\.viewerID) }
    /// Viewers whose relay-side revocation has not been acknowledged yet (retried by `flushOutbox`).
    public var unacknowledgedRevocations: Set<ViewerID> { Set(desiredOnRelay.filter { !$0.value.onShare }.keys) }
    /// True when `stop()` could not reach the relay yet (retried by `flushOutbox`).
    public var stopUnacknowledged: Bool { pendingRelayStop }
    /// Viewers added locally whose relay-side add has not been acknowledged yet (retried by `flushOutbox`).
    public var unacknowledgedAdds: Set<ViewerID> { Set(desiredOnRelay.filter { $0.value.onShare }.keys) }

    /// Adds (or re-adds) a viewer. The key is validated first; nothing changes if it is bad. Then the next
    /// point is sealed for them and the relay is told.
    ///
    /// Relay calls for one viewer are **single-flight**: at most one is in the air, and when it returns the
    /// session sends whatever the latest local intent is by then (on the share, or not), until the relay has
    /// acknowledged the latest intent. Calls made meanwhile only update the intent.
    /// - Returns: whether the relay acknowledged and the viewer is on the share (a `revoke` made while the
    ///   add was in flight wins, and then this is `false`). Otherwise `false` means it is
    ///   still pending (offline, or another call for this viewer is in flight); `flushOutbox` finishes it,
    ///   and a refusal met then is reported in `refusedAdds`.
    /// - Throws: `FanoutCryptoError.badViewerKey`; `SessionError.shareEnded` if the share ended before or
    ///   during the call (after `stop()`, or the relay no longer knows the share); `RelayError.tooManyViewers`
    ///   if the relay refused (the viewer is then removed locally too).
    @discardableResult
    public func addViewer(_ viewer: ViewerID, publicKey: Data) async throws -> Bool {
        guard !isEnded else { throw SessionError.shareEnded }
        try sealer.add(viewer, publicKey: publicKey)
        refusedAdds[viewer] = nil
        setIntent(viewer, onShare: true)
        let acknowledged = try await reconcile(viewer)
        if isEnded { throw SessionError.shareEnded }                // stop() ran while the add was in flight
        return acknowledged && sealer.recipients.contains(viewer)
    }

    private func setIntent(_ viewer: ViewerID, onShare: Bool) {
        intentEpoch = Saturating.add(intentEpoch, 1)
        desiredOnRelay[viewer] = Intent(onShare: onShare, epoch: intentEpoch)
    }

    /// Drives the relay towards `desiredOnRelay[viewer]`, one call at a time. Terminates: it only loops when
    /// the intent changed during the previous call, and each change needs a new `revoke`/`addViewer`.
    /// - Returns: `true` only when the relay acknowledged the latest intent; `false` when it is still
    ///   pending, or was dropped because the share ended.
    private func reconcile(_ viewer: ViewerID) async throws -> Bool {
        guard !reconciling.contains(viewer) else { return false }   // the in-flight call will pick up the intent
        reconciling.insert(viewer)
        defer { reconciling.remove(viewer) }
        while let sent = desiredOnRelay[viewer] {
            if sent.onShare && isEnded { desiredOnRelay[viewer] = nil; return false }
            do {
                if sent.onShare { try await uplink.addViewer(viewer, to: shareID) }
                else { try await uplink.revoke(viewer, from: shareID) }
            } catch let refusal as RelayError where sent.onShare {
                // A refusal is final only if it answers the exact latest intent; otherwise send the new one.
                guard desiredOnRelay[viewer]?.epoch == sent.epoch else { continue }
                desiredOnRelay[viewer] = nil
                if refusal == .unknownShare { endLocally(); throw SessionError.shareEnded }
                sealer.revoke(viewer)
                outbox.removeAll { $0.viewerID == viewer }
                refusedAdds[viewer] = refusal
                throw refusal
            } catch RelayError.unknownShare where !sent.onShare {
                // The relay no longer knows the share, so the viewer is not on it: that is the revoke done.
            } catch {
                return false                                    // transport failure: stays pending
            }
            // Calls are serial, so after an acknowledged call the relay holds `sent.onShare`. If the latest
            // intent wants the same, it is satisfied too; if it changed (or the share ended), loop on what is left.
            if desiredOnRelay[viewer]?.onShare == sent.onShare { desiredOnRelay[viewer] = nil; return true }
        }
        return false
    }

    /// Feeds one fix from CoreLocation (or a simulator route).
    public func ingest(_ fix: LocationFix, conditions: DeviceConditions) async -> IngestOutcome {
        guard !isEnded else { return .ended }
        let now = clock.now()
        counters.fixesSeen = Saturating.add(counters.fixesSeen, 1)
        let cadence = PublishPolicy.cadence(for: conditions, presenceTTL: presenceTTL)
        lastCadence = cadence
        budget.refill(now: now)
        let decision = gate.decide(fix, now: now, cadence: cadence, discretionaryAllowed: budget.tokens > 0)
        let reason: PublishReason
        switch decision {
        case .suppress(let why):
            counters.suppressed[why] = Saturating.add(counters.suppressed[why] ?? 0, 1)
            return .suppressed(why)
        case .publish(let r):
            reason = r
        }
        // A heartbeat that falls due on a poor fix re-sends the last good fix instead, so a cell-tower
        // estimate can never jump the pin.
        var toSend = fix
        if reason == .heartbeat, fix.accuracyMeters > gate.maxAccuracyMeters, let good = gate.lastPublished {
            toSend = good
        }
        return await send(PointPayload(fix: toSend, sentAt: now, reason: reason), spendsBudget: reason == .moved)
    }

    /// Call on a timer. Sends a heartbeat (the last fix, fresh `sentAt`) if one is owed.
    public func tick(conditions: DeviceConditions) async -> IngestOutcome {
        guard !isEnded else { return .ended }
        let now = clock.now()
        let cadence = PublishPolicy.cadence(for: conditions, presenceTTL: presenceTTL)
        lastCadence = cadence
        guard gate.heartbeatDue(now: now, cadence: cadence), let last = gate.lastPublished else { return .idle }
        return await send(PointPayload(fix: last, sentAt: now, reason: .heartbeat), spendsBudget: false)
    }

    /// Retries pending relay revocations, adds and stop, then the held batch, if any. Location is
    /// latest-wins, so only the newest batch is ever kept. An add the relay refuses here is dropped and
    /// reported in `refusedAdds`.
    public func flushOutbox() async -> IngestOutcome {
        // Relay-side cleanup is retried even after the share ended: a revoke or stop that failed offline
        // must still reach the relay, or it would keep stored copies until the share expires.
        for viewer in desiredOnRelay.keys.sorted() { _ = try? await reconcile(viewer) }
        if pendingRelayStop, await stopAtRelay() { pendingRelayStop = false }
        guard !isEnded else { return .ended }
        // The outbox never holds a copy for a revoked viewer: `send` filters on the way in and `revoke`
        // removes on the way out, so it can be uploaded as is.
        guard !outbox.isEmpty else { return .idle }
        let batch = outbox, seq = outboxSequence, reason = outboxReason
        do {
            let receipt = try await uplink.upload(batch)
            if outboxSequence == seq { outbox = [] }             // a newer batch may have replaced it meanwhile
            if receipt.accepted { counters.uploaded = Saturating.add(counters.uploaded, 1) }
            guard !isEnded else { return .ended }                            // stop() ran during the upload
            if receipt.shareIsGone { endLocally(); return .ended }
            return receipt.accepted ? .published(reason, sequence: seq, receipt: receipt)
                                    : .rejected(sequence: seq, receipt: receipt)
        } catch {
            guard !isEnded else { return .ended }
            // Nothing held if a newer batch uploaded meanwhile, or a revoke emptied the outbox.
            return outbox.isEmpty ? .idle : .heldOffline(sequence: seq)
        }
    }

    /// Revokes locally *first* — nothing new is sealed for `viewer` after this line, and the outbox drops
    /// them even if an in-flight upload fails back into it — then tells the relay to delete its copy.
    /// A batch already in flight may still arrive; the relay refuses it once its revocation lands.
    /// - Returns: `true` when no relay work is pending for this viewer: the relay holds the latest intent,
    ///   it finally refused a later add (see `refusedAdds`), or the share ended. `false` while a call is in
    ///   flight or failed; `flushOutbox` finishes it.
    @discardableResult
    public func revoke(_ viewer: ViewerID) async -> Bool {
        sealer.revoke(viewer)
        outbox.removeAll { $0.viewerID == viewer }
        setIntent(viewer, onShare: false)
        _ = try? await reconcile(viewer)
        return desiredOnRelay[viewer] == nil
    }

    /// Ends the share: nothing more is sealed or uploaded, and the relay is asked to delete everything.
    /// - Returns: whether the relay acknowledged. If not, `flushOutbox` retries it (and any pending revokes).
    @discardableResult
    public func stop() async -> Bool {
        endLocally()
        let acknowledged = await stopAtRelay()
        pendingRelayStop = !acknowledged
        return acknowledged
    }

    /// `unknownShare` counts as acknowledged: a share the relay has forgotten is already stopped.
    private func stopAtRelay() async -> Bool {
        do { try await uplink.stop(shareID); return true }
        catch RelayError.unknownShare { return true }
        catch { return false }
    }

    /// Local end: drop the outbox and pending adds. Pending revocations are kept so `flushOutbox` can still
    /// deliver them.
    private func endLocally() {
        isEnded = true
        outbox = []
        desiredOnRelay = desiredOnRelay.filter { !$0.value.onShare }
    }

    private func send(_ payload: PointPayload, spendsBudget: Bool) async -> IngestOutcome {
        // Clock-driven by default: the sequence never falls behind wall-clock ms × 2¹⁶, so a junk copy the
        // relay accepted (at most `LocationRelay.maxSequenceLead` ahead) blocks this share only until the
        // clock passes it, not for the rest of the session.
        let seq = clockDrivenSequence ? max(nextSequence, Self.epochSequence(payload.sentAt)) : nextSequence
        let copies: [SealedPoint]
        do { copies = try sealer.sealCopies(payload, sequence: seq) } catch { return .idle }
        guard !copies.isEmpty else { return .idle }
        // Commit only once something was actually sealed: a failed seal must not reset the heartbeat clock.
        // UInt64 cannot realistically wrap (see `epochSequence`); saturate anyway.
        nextSequence = seq == .max ? .max : seq + 1
        if spendsBudget { _ = budget.tryTake(now: payload.sentAt) }
        gate.commit(payload.fix, at: payload.sentAt)
        counters.sealed = Saturating.add(counters.sealed, 1)
        if payload.reason == .heartbeat { counters.heartbeats = Saturating.add(counters.heartbeats, 1) }
        do {
            let receipt = try await uplink.upload(copies)
            if receipt.accepted { counters.uploaded = Saturating.add(counters.uploaded, 1) }
            guard !isEnded else { return .ended }                            // stop() ran during the upload
            if outboxSequence <= seq { outbox = []; outboxSequence = seq }   // supersedes anything older
            if receipt.shareIsGone { endLocally(); return .ended }
            return receipt.accepted ? .published(payload.reason, sequence: seq, receipt: receipt)
                                    : .rejected(sequence: seq, receipt: receipt)
        } catch {
            guard !isEnded else { return .ended }                            // never refill the outbox after stop()
            if seq > outboxSequence {
                // Re-filter: a revoke may have run while this upload was in flight.
                let current = Set(sealer.recipients)
                outbox = copies.filter { current.contains($0.viewerID) }
                outboxSequence = seq
                outboxReason = payload.reason
                if outbox.isEmpty { return .idle }               // everyone it was for was revoked meanwhile
            } else if outbox.isEmpty {
                return .idle                                     // a newer batch was already uploaded
            }
            counters.heldOffline = Saturating.add(counters.heldOffline, 1)
            return .heldOffline(sequence: seq)
        }
    }
}
