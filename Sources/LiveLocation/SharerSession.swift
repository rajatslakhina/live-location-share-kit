import Foundation

/// The sharer's path to the relay. `LocationRelay` conforms directly (in-process, as in the demo);
/// a production client would implement it over HTTPS.
public protocol RelayUplink: Sendable {
    func upload(_ copies: [SealedPoint]) async throws -> PublishReceipt
    func revoke(_ viewer: ViewerID, from share: ShareID) async throws
}

extension LocationRelay: RelayUplink {
    public func upload(_ copies: [SealedPoint]) async throws -> PublishReceipt { publish(copies) }
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
}

public struct SessionCounters: Sendable, Hashable {
    public internal(set) var fixesSeen = 0
    public internal(set) var published = 0
    public internal(set) var heartbeats = 0
    public internal(set) var suppressed: [SuppressReason: Int] = [:]
    public internal(set) var heldOffline = 0
    public init() {}
}

/// Sharer-side coordinator: `PublishPolicy` → `PublishGate` → battery `TokenBucket` → `PerViewerSealer`
/// → `RelayUplink`, with a latest-wins offline outbox.
///
/// **Reentrancy.** Everything that must be atomic — the gate decision, the budget token, the gate commit,
/// the sequence number and the sealing — happens *before* the only `await` (the upload). Two concurrent
/// `ingest` calls therefore always get distinct, increasing sequence numbers, and if their uploads land
/// out of order the relay's monotonic check drops the older one. After the `await`, the outbox is only
/// ever replaced by a *newer* sequence.
public actor SharerSession {
    public let shareID: ShareID
    private var sealer: PerViewerSealer
    private let uplink: any RelayUplink
    private let clock: any LiveClock
    private let presenceTTL: Millis

    private var gate: PublishGate
    private var budget: TokenBucket
    private var nextSequence: UInt64 = 1
    private var outbox: [SealedPoint] = []
    private var outboxSequence: UInt64 = 0
    private var outboxReason: PublishReason = .moved
    public private(set) var counters = SessionCounters()
    public private(set) var lastCadence: PublishCadence?

    /// - Parameters:
    ///   - discretionaryBudget: movement publishes allowed per session as a burst, refilling one per
    ///     `budgetRefill`. Heartbeats never spend it — presence must not die because the user walked a lot.
    public init(shareID: ShareID, manifest: CapabilityManifest, sealer: PerViewerSealer,
                uplink: any RelayUplink, clock: any LiveClock, presenceTTL: Millis,
                discretionaryBudget: Int = 120, budgetRefill: Millis = .seconds(30),
                maxAccuracyMeters: Double = 200) throws {
        guard manifest.capabilities.contains(.liveLocationSharing) else { throw SessionError.capabilityNotDeclared }
        self.shareID = shareID
        self.sealer = sealer
        self.uplink = uplink
        self.clock = clock
        self.presenceTTL = presenceTTL
        self.gate = PublishGate(maxAccuracyMeters: maxAccuracyMeters)
        self.budget = TokenBucket(capacity: discretionaryBudget, refillEvery: budgetRefill, now: clock.now())
    }

    public var recipients: [ViewerID] { sealer.recipients }
    public var budgetRemaining: Int { budget.tokens }

    /// Feeds one fix from CoreLocation (or a simulator route).
    public func ingest(_ fix: LocationFix, conditions: DeviceConditions) async -> IngestOutcome {
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
        if reason == .moved { _ = budget.tryTake(now: now) }
        gate.commit(fix, at: now)
        return await send(PointPayload(fix: fix, sentAt: now, reason: reason))
    }

    /// Call on a timer. Sends a heartbeat (the last fix, fresh `sentAt`) if one is owed.
    public func tick(conditions: DeviceConditions) async -> IngestOutcome {
        let now = clock.now()
        let cadence = PublishPolicy.cadence(for: conditions, presenceTTL: presenceTTL)
        lastCadence = cadence
        guard gate.heartbeatDue(now: now, cadence: cadence), let last = gate.lastPublished else { return .idle }
        gate.commit(last, at: now)
        return await send(PointPayload(fix: last, sentAt: now, reason: .heartbeat))
    }

    /// Retries the held batch, if any. Location is latest-wins, so only the newest batch is ever kept.
    public func flushOutbox() async -> IngestOutcome {
        guard !outbox.isEmpty else { return .idle }
        let batch = outbox, seq = outboxSequence, reason = outboxReason
        do {
            let receipt = try await uplink.upload(batch)
            if outboxSequence == seq { outbox = [] }             // a newer batch may have replaced it meanwhile
            return .published(reason, sequence: seq, receipt: receipt)
        } catch {
            return .heldOffline(sequence: seq)
        }
    }

    /// Revokes locally *first* — no copy for `viewer` can be sealed after this line even if the network call
    /// below fails or another `ingest` interleaves at the `await` — then tells the relay to delete its copy.
    public func revoke(_ viewer: ViewerID) async {
        sealer.revoke(viewer)
        outbox.removeAll { $0.viewerID == viewer }
        try? await uplink.revoke(viewer, from: shareID)
    }

    private func send(_ payload: PointPayload) async -> IngestOutcome {
        let seq = nextSequence
        // UInt64 cannot realistically wrap (one publish per second for 5×10^11 years); saturate anyway.
        nextSequence = nextSequence == .max ? .max : nextSequence + 1
        let copies: [SealedPoint]
        do { copies = try sealer.sealCopies(payload, sequence: seq) } catch { return .idle }
        guard !copies.isEmpty else { return .idle }
        counters.published = Saturating.add(counters.published, 1)
        if payload.reason == .heartbeat { counters.heartbeats = Saturating.add(counters.heartbeats, 1) }
        do {
            let receipt = try await uplink.upload(copies)
            if outboxSequence <= seq { outbox = []; outboxSequence = seq }   // supersedes anything older
            return .published(payload.reason, sequence: seq, receipt: receipt)
        } catch {
            if seq > outboxSequence { outbox = copies; outboxSequence = seq; outboxReason = payload.reason }
            counters.heldOffline = Saturating.add(counters.heldOffline, 1)
            return .heldOffline(sequence: seq)
        }
    }
}
