import Foundation

/// The sharer's path to the relay. `LocationRelay` conforms directly (in-process, as in the demo);
/// a production client would implement it over HTTPS.
public protocol RelayUplink: Sendable {
    func upload(_ copies: [SealedPoint]) async throws -> PublishReceipt
    func revoke(_ viewer: ViewerID, from share: ShareID) async throws
    func stop(_ share: ShareID) async throws
}

extension LocationRelay: RelayUplink {
    public func upload(_ copies: [SealedPoint]) async throws -> PublishReceipt { publish(copies) }
    public func stop(_ share: ShareID) async throws { stopShare(share) }
}

public enum SessionError: Error, Equatable, Sendable {
    /// The app's capability manifest does not declare `.liveLocationSharing`, so the session refuses
    /// to exist. This is what ties runtime behaviour to the age-rating declaration (see `AgeRatingGate`).
    case capabilityNotDeclared
}

public enum IngestOutcome: Sendable, Hashable {
    case published(PublishReason, sequence: UInt64, receipt: PublishReceipt)
    case suppressed(SuppressReason)
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
    /// Batches the relay actually received (including ones flushed from the offline outbox).
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
/// number, the sealing and the gate commit — happens *before* the only `await` (the upload). Two
/// concurrent `ingest` calls therefore always get distinct, increasing sequence numbers, and if their
/// uploads land out of order the relay's monotonic check drops the older one. After the `await`, the
/// outbox is only ever replaced by a *newer* sequence, and only with copies for current recipients.
///
/// **Relaunch.** iOS kills background apps mid-share. To resume, persist `sealer.privateKeyRaw` (Keychain)
/// and restore with `PerViewerSealer(shareID:privateKeyRaw:)`. Sequences need no persistence by default:
/// they start at `epochSequence(now)` = wall-clock ms × 2¹⁶, so a relaunched session always starts above
/// everything the previous one sent (unless the device clock is set back).
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
    public private(set) var isEnded = false
    public private(set) var counters = SessionCounters()
    public private(set) var lastCadence: PublishCadence?

    /// - Parameters:
    ///   - presenceTTL: must be the relay's `configuration.presenceTTL` (clamped to ≥ 2 s like the relay's).
    ///   - discretionaryBudget: movement publishes allowed per session as a burst, refilling one per
    ///     `budgetRefill`. Heartbeats never spend it — presence must not die because the user walked a lot.
    ///   - startingSequence: defaults to `epochSequence(clock.now())`; pass an explicit value only in tests
    ///     or if you persist sequences yourself.
    public init(shareID: ShareID, manifest: CapabilityManifest, sealer: PerViewerSealer,
                uplink: any RelayUplink, clock: any LiveClock, presenceTTL: Millis,
                discretionaryBudget: Int = 120, budgetRefill: Millis = .seconds(30),
                maxAccuracyMeters: Double = 200, startingSequence: UInt64? = nil) throws {
        guard manifest.capabilities.contains(.liveLocationSharing) else { throw SessionError.capabilityNotDeclared }
        self.shareID = shareID
        self.sealer = sealer
        self.uplink = uplink
        self.clock = clock
        self.presenceTTL = max(PublishPolicy.minimumPresenceTTL, presenceTTL)
        self.gate = PublishGate(maxAccuracyMeters: maxAccuracyMeters)
        self.budget = TokenBucket(capacity: discretionaryBudget, refillEvery: budgetRefill, now: clock.now())
        self.nextSequence = max(1, startingSequence ?? Self.epochSequence(clock.now()))
    }

    /// Wall-clock milliseconds × 65,536. Strictly above any sequence a previous session on the same share
    /// could have reached unless it published more than 65,536 points per millisecond since it started.
    public static func epochSequence(_ now: Instant) -> UInt64 {
        let ms = UInt64(clamping: max(0, now.millis))
        let (shifted, overflow) = ms.multipliedReportingOverflow(by: 1 << 16)
        return overflow ? UInt64.max / 2 : shifted
    }

    public var recipients: [ViewerID] { sealer.recipients }
    public var budgetRemaining: Int { budget.tokens }
    /// The sequence the next batch will carry.
    public var upcomingSequence: UInt64 { nextSequence }
    /// Who the held offline batch is addressed to (empty when nothing is held).
    public var heldBatchRecipients: [ViewerID] { outbox.map(\.viewerID) }
    /// Viewers whose relay-side revocation has not been acknowledged yet (retried by `flushOutbox`).
    public var unacknowledgedRevocations: Set<ViewerID> { pendingRelayRevocations }

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
        guard !isEnded else { return .ended }
        for viewer in pendingRelayRevocations.sorted() {
            if (try? await uplink.revoke(viewer, from: shareID)) != nil { pendingRelayRevocations.remove(viewer) }
        }
        // The outbox never holds a copy for a revoked viewer: `send` filters on the way in and `revoke`
        // removes on the way out, so it can be uploaded as is.
        guard !outbox.isEmpty else { return .idle }
        let batch = outbox, seq = outboxSequence, reason = outboxReason
        do {
            let receipt = try await uplink.upload(batch)
            if outboxSequence == seq { outbox = [] }             // a newer batch may have replaced it meanwhile
            counters.uploaded = Saturating.add(counters.uploaded, 1)
            if receipt.shareIsGone { endLocally(); return .ended }
            return .published(reason, sequence: seq, receipt: receipt)
        } catch {
            return .heldOffline(sequence: seq)
        }
    }

    /// Revokes locally *first* — no copy for `viewer` can be sealed or uploaded after this line, even if
    /// an upload is in flight and fails back into the outbox — then tells the relay to delete its copy.
    /// - Returns: whether the relay acknowledged. If not, `flushOutbox` retries it.
    @discardableResult
    public func revoke(_ viewer: ViewerID) async -> Bool {
        sealer.revoke(viewer)
        outbox.removeAll { $0.viewerID == viewer }
        do {
            try await uplink.revoke(viewer, from: shareID)
            pendingRelayRevocations.remove(viewer)
            return true
        } catch {
            pendingRelayRevocations.insert(viewer)
            return false
        }
    }

    /// Ends the share: nothing more is sealed or uploaded, and the relay is asked to delete everything.
    public func stop() async {
        endLocally()
        try? await uplink.stop(shareID)
    }

    private func endLocally() {
        isEnded = true
        outbox = []
        pendingRelayRevocations = []
    }

    private func send(_ payload: PointPayload, spendsBudget: Bool) async -> IngestOutcome {
        let seq = nextSequence
        let copies: [SealedPoint]
        do { copies = try sealer.sealCopies(payload, sequence: seq) } catch { return .idle }
        guard !copies.isEmpty else { return .idle }
        // Commit only once something was actually sealed: a failed seal must not reset the heartbeat clock.
        // UInt64 cannot realistically wrap (see `epochSequence`); saturate anyway.
        nextSequence = nextSequence == .max ? .max : nextSequence + 1
        if spendsBudget { _ = budget.tryTake(now: payload.sentAt) }
        gate.commit(payload.fix, at: payload.sentAt)
        counters.sealed = Saturating.add(counters.sealed, 1)
        if payload.reason == .heartbeat { counters.heartbeats = Saturating.add(counters.heartbeats, 1) }
        do {
            let receipt = try await uplink.upload(copies)
            counters.uploaded = Saturating.add(counters.uploaded, 1)
            if outboxSequence <= seq { outbox = []; outboxSequence = seq }   // supersedes anything older
            if receipt.shareIsGone { endLocally(); return .ended }
            return .published(payload.reason, sequence: seq, receipt: receipt)
        } catch {
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
