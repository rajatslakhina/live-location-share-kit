import Foundation

/// The sharer's path to the relay. `LocationRelay` conforms directly (in-process, as in the demo);
/// a production client would implement it over HTTPS.
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
    /// Sealed, but the uplink failed; kept in a one-slot, latest-wins outbox.
    case heldOffline(sequence: UInt64)
    /// Nothing to send (no recipients left, or no prior fix to heartbeat).
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
/// `stopUnacknowledged`, and re-apply them after relaunch. The battery budget and the publish gate start
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
    private var pendingRelayRevocations: Set<ViewerID> = []
    private var pendingRelayAdds: Set<ViewerID> = []
    /// Default mode: sequences follow the wall clock (see `send`). Off when the caller passes
    /// `startingSequence`, which gives a plain counter (tests, or apps that persist sequences).
    private let clockDrivenSequence: Bool
    private var pendingRelayStop = false
    public private(set) var isEnded = false
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
    public var unacknowledgedRevocations: Set<ViewerID> { pendingRelayRevocations }
    /// True when `stop()` could not reach the relay yet (retried by `flushOutbox`).
    public var stopUnacknowledged: Bool { pendingRelayStop }
    /// Viewers added locally whose relay-side add has not been acknowledged yet (retried by `flushOutbox`).
    public var unacknowledgedAdds: Set<ViewerID> { pendingRelayAdds }

    /// Adds (or re-adds) a viewer. The key is validated first; nothing changes if it is bad. Then the next
    /// point is sealed for them, any pending revocation of them is cancelled, and the relay is told.
    /// Relay operations for one viewer are reconciled after every `await`, so a revoke and an add that
    /// interleave always converge to the latest local intent.
    /// - Returns: whether the relay acknowledged. If not, `flushOutbox` retries it (`unacknowledgedAdds`).
    /// - Throws: `FanoutCryptoError.badViewerKey`, or `SessionError.shareEnded` after `stop()`.
    @discardableResult
    public func addViewer(_ viewer: ViewerID, publicKey: Data) async throws -> Bool {
        guard !isEnded else { throw SessionError.shareEnded }
        try sealer.add(viewer, publicKey: publicKey)
        pendingRelayRevocations.remove(viewer)
        pendingRelayAdds.insert(viewer)
        return await syncAdd(viewer)
    }

    /// Sends a pending add and clears it only if the viewer is still a recipient afterwards.
    private func syncAdd(_ viewer: ViewerID) async -> Bool {
        let ok = (try? await uplink.addViewer(viewer, to: shareID)) != nil
        if ok, sealer.recipients.contains(viewer) { pendingRelayAdds.remove(viewer) }
        return ok
    }

    /// Sends a pending revoke and reconciles with any `addViewer` that ran during the `await`.
    private func syncRevoke(_ viewer: ViewerID) async -> Bool {
        let ok = (try? await uplink.revoke(viewer, from: shareID)) != nil
        if sealer.recipients.contains(viewer) {
            // Re-added while the revoke was in flight: the relay may have applied the revoke *after* the
            // add, so the add is re-sent.
            pendingRelayRevocations.remove(viewer)
            pendingRelayAdds.insert(viewer)
            _ = await syncAdd(viewer)
        } else if ok {
            pendingRelayRevocations.remove(viewer)
        }
        return ok
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

    /// Retries unacknowledged relay revocations, then the held batch, if any. Location is latest-wins,
    /// so only the newest batch is ever kept.
    public func flushOutbox() async -> IngestOutcome {
        // Relay-side cleanup is retried even after the share ended: a revoke or stop that failed offline
        // must still reach the relay, or it would keep stored copies until the share expires.
        for viewer in pendingRelayRevocations.sorted() where pendingRelayRevocations.contains(viewer) {
            _ = await syncRevoke(viewer)
        }
        for viewer in pendingRelayAdds.sorted() where pendingRelayAdds.contains(viewer) {
            if sealer.recipients.contains(viewer) { _ = await syncAdd(viewer) } else { pendingRelayAdds.remove(viewer) }
        }
        if pendingRelayStop, (try? await uplink.stop(shareID)) != nil { pendingRelayStop = false }
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
            return .heldOffline(sequence: seq)
        }
    }

    /// Revokes locally *first* — nothing new is sealed for `viewer` after this line, and the outbox drops
    /// them even if an in-flight upload fails back into it — then tells the relay to delete its copy.
    /// A batch already in flight may still arrive; the relay refuses it once its revocation lands.
    /// - Returns: whether the relay acknowledged. If not, `flushOutbox` retries it.
    @discardableResult
    public func revoke(_ viewer: ViewerID) async -> Bool {
        sealer.revoke(viewer)
        outbox.removeAll { $0.viewerID == viewer }
        pendingRelayAdds.remove(viewer)
        pendingRelayRevocations.insert(viewer)
        return await syncRevoke(viewer)
    }

    /// Ends the share: nothing more is sealed or uploaded, and the relay is asked to delete everything.
    /// - Returns: whether the relay acknowledged. If not, `flushOutbox` retries it (and any pending revokes).
    @discardableResult
    public func stop() async -> Bool {
        endLocally()
        do {
            try await uplink.stop(shareID)
            pendingRelayStop = false
            return true
        } catch {
            pendingRelayStop = true
            return false
        }
    }

    /// Local end: drop the outbox. Pending relay revocations are kept so `flushOutbox` can still deliver them.
    private func endLocally() {
        isEnded = true
        outbox = []
        pendingRelayAdds = []
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
            }
            counters.heldOffline = Saturating.add(counters.heldOffline, 1)
            return .heldOffline(sequence: seq)
        }
    }
}
