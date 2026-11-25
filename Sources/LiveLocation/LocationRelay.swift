import Foundation

public struct RelayConfiguration: Sendable, Hashable {
    /// A share with no accepted copy for this long reads as `.away`. Clamped to ≥ 2 s so the sharer's
    /// heartbeat (TTL / 2, floored at 1 s) is always strictly shorter than it.
    public var presenceTTL: Millis
    /// Upper bound on any share's lifetime. "Share until I stop" is still capped; nothing is forever.
    public var maxShareDuration: Millis
    public var maxViewersPerShare: Int
    public var maxActiveShares: Int
    /// Per-viewer push budget (background delivery): burst of `pushBurst`, then one per `pushRefill`.
    public var pushBurst: Int
    public var pushRefill: Millis
    /// Per-connection buffer. A slow foreground consumer drops its *oldest* events, never blocks the relay.
    public var connectionBuffer: Int

    public init(presenceTTL: Millis = .seconds(120), maxShareDuration: Millis = .hours(24),
                maxViewersPerShare: Int = 50, maxActiveShares: Int = 10_000,
                pushBurst: Int = 4, pushRefill: Millis = .minutes(5), connectionBuffer: Int = 32) {
        self.presenceTTL = max(Millis.seconds(2), presenceTTL)
        self.maxShareDuration = max(Millis.seconds(1), maxShareDuration)
        self.maxViewersPerShare = max(1, maxViewersPerShare)
        self.maxActiveShares = max(1, maxActiveShares)
        self.pushBurst = max(1, pushBurst)
        self.pushRefill = max(Millis(1), pushRefill)
        self.connectionBuffer = max(1, connectionBuffer)
    }
}

public enum EndReason: String, Sendable, Hashable { case expired, stopped }

/// What a connected (foreground) viewer receives.
public enum RelayEvent: Sendable, Hashable {
    case point(SealedPoint)
    case revoked(ShareID)
    case ended(ShareID, EndReason)
}

public enum RelayError: Error, Equatable, Sendable {
    case invalidDuration
    case noViewers
    case tooManyViewers(limit: Int)
    case capacityReached(limit: Int)
    case duplicateShare
}

public enum RejectReason: String, Sendable, Hashable {
    case unknownShare, shareExpired, notARecipient, staleSequence
}

public struct PublishReceipt: Sendable, Hashable {
    public internal(set) var deliveredLive: [ViewerID] = []
    public internal(set) var queuedForPush: [ViewerID] = []
    public internal(set) var rejected: [ViewerID: RejectReason] = [:]
    public init() {}
}

/// One background push the relay hands to APNs (a Live Activity update carrying the sealed copy).
public struct PushDelivery: Sendable, Hashable {
    public let viewer: ViewerID
    public let sealed: SealedPoint
    /// How many newer points replaced an undelivered one while this push waited for budget.
    public let coalesced: Int
}

public enum Presence: Sendable, Hashable {
    case online(lastSeen: Instant)
    case away(lastSeen: Instant)
    /// The share exists but the sharer has not published a first point yet.
    case awaitingFirstPoint
    case unknownShare
}

public struct RelayStats: Sendable, Hashable {
    public let activeShares: Int
    public let storedPoints: Int
    public let pendingPushes: Int
    public let liveConnections: Int
    public let pushesSent: Int
    public let pushesCoalesced: Int
}

/// The server half of the system, modelled as one actor: presence with a TTL, **only the latest copy per
/// (share, viewer)**, time- and revocation-based expiry, foreground fan-out over a stream (the WebSocket
/// path) and budgeted, coalescing background pushes (the Live Activity path).
///
/// Every method is synchronous inside the actor — there is no `await` between reading and writing state,
/// so there is no actor-reentrancy window. Storage is bounded by `maxActiveShares × maxViewersPerShare`.
public actor LocationRelay {
    struct ShareRecord {
        var viewers: Set<ViewerID>
        let expiresAt: Instant
        var lastSeen: Instant?
    }
    struct Pending {
        var sealed: SealedPoint
        var coalesced: Int
    }

    public let configuration: RelayConfiguration
    private let clock: any LiveClock

    private var shares: [ShareID: ShareRecord] = [:]
    private var latest: [ShareID: [ViewerID: SealedPoint]] = [:]
    private var pending: [ViewerID: [ShareID: Pending]] = [:]
    private var pushBudgets: [ViewerID: TokenBucket] = [:]
    private var connections: [ViewerID: [UUID: AsyncStream<RelayEvent>.Continuation]] = [:]
    private var pushesSent = 0
    private var pushesCoalesced = 0

    public init(configuration: RelayConfiguration = RelayConfiguration(), clock: any LiveClock = SystemClock()) {
        self.configuration = configuration
        self.clock = clock
    }

    // MARK: Share lifecycle

    /// - Returns: the expiry instant.
    @discardableResult
    public func startShare(_ id: ShareID, viewers: Set<ViewerID>, duration: Millis) throws -> Instant {
        guard duration > .zero, duration <= configuration.maxShareDuration else { throw RelayError.invalidDuration }
        guard !viewers.isEmpty else { throw RelayError.noViewers }
        guard viewers.count <= configuration.maxViewersPerShare else {
            throw RelayError.tooManyViewers(limit: configuration.maxViewersPerShare)
        }
        guard shares[id] == nil else { throw RelayError.duplicateShare }
        _ = sweep()
        guard shares.count < configuration.maxActiveShares else {
            throw RelayError.capacityReached(limit: configuration.maxActiveShares)
        }
        let expiresAt = clock.now().adding(duration)
        shares[id] = ShareRecord(viewers: viewers, expiresAt: expiresAt, lastSeen: nil)
        return expiresAt
    }

    /// Removes one viewer: their stored copy and queued push are deleted immediately and their open
    /// connections get `.revoked`. The sharer's device stops sealing for them too (`PerViewerSealer.revoke`),
    /// so this is defence in depth, not the only line.
    public func revoke(_ viewer: ViewerID, from share: ShareID) {
        guard shares[share]?.viewers.remove(viewer) != nil else { return }
        latest[share]?[viewer] = nil
        pending[viewer]?[share] = nil
        if pending[viewer]?.isEmpty == true { pending[viewer] = nil }
        send(.revoked(share), to: viewer)
        dropBudgetIfIdle(viewer)
    }

    public func stopShare(_ id: ShareID) { end(id, reason: .stopped) }

    /// Ends every share whose expiry has passed. Called on each start and publish, and by a timer in a
    /// real server; idempotent.
    @discardableResult
    public func sweep() -> [ShareID] {
        let now = clock.now()
        let expired = shares.filter { now >= $0.value.expiresAt }.keys.sorted { $0.raw < $1.raw }
        for id in expired { end(id, reason: .expired) }
        return expired
    }

    // MARK: Publish + fan-out

    public func publish(_ copies: [SealedPoint]) -> PublishReceipt {
        let now = clock.now()
        _ = sweep()
        var receipt = PublishReceipt()
        for copy in copies {
            guard var record = shares[copy.shareID] else {
                receipt.rejected[copy.viewerID] = .unknownShare   // includes shares just swept
                continue
            }
            guard now < record.expiresAt else { receipt.rejected[copy.viewerID] = .shareExpired; continue }
            guard record.viewers.contains(copy.viewerID) else {
                receipt.rejected[copy.viewerID] = .notARecipient
                continue
            }
            // Latest-wins with a monotonic sequence: an older copy that arrives late is dropped, so
            // out-of-order delivery can never move a viewer's pin backwards.
            if let stored = latest[copy.shareID]?[copy.viewerID], copy.sequence <= stored.sequence {
                receipt.rejected[copy.viewerID] = .staleSequence
                continue
            }
            latest[copy.shareID, default: [:]][copy.viewerID] = copy
            record.lastSeen = now
            shares[copy.shareID] = record

            if let conns = connections[copy.viewerID], !conns.isEmpty {
                for c in conns.values { c.yield(.point(copy)) }
                receipt.deliveredLive.append(copy.viewerID)
            } else {
                enqueuePush(copy)
                receipt.queuedForPush.append(copy.viewerID)
            }
        }
        return receipt
    }

    private func enqueuePush(_ copy: SealedPoint) {
        if let existing = pending[copy.viewerID]?[copy.shareID] {
            pending[copy.viewerID]?[copy.shareID] = Pending(sealed: copy, coalesced: Saturating.add(existing.coalesced, 1))
            pushesCoalesced = Saturating.add(pushesCoalesced, 1)
        } else {
            pending[copy.viewerID, default: [:]][copy.shareID] = Pending(sealed: copy, coalesced: 0)
        }
    }

    /// Hands every pending push that has budget to the caller (the APNs sender). Pushes without budget
    /// stay queued — coalesced to the newest point — until a token refills.
    public func drainPushes() -> [PushDelivery] {
        let now = clock.now()
        var out: [PushDelivery] = []
        for viewer in pending.keys.sorted() {
            guard let queue = pending[viewer] else { continue }
            var bucket = pushBudgets[viewer]
                ?? TokenBucket(capacity: configuration.pushBurst, refillEvery: configuration.pushRefill, now: now)
            for share in queue.keys.sorted(by: { $0.raw < $1.raw }) {
                guard let item = queue[share], bucket.tryTake(now: now) else { break }
                out.append(PushDelivery(viewer: viewer, sealed: item.sealed, coalesced: item.coalesced))
                pending[viewer]?[share] = nil
                pushesSent = Saturating.add(pushesSent, 1)
            }
            pushBudgets[viewer] = bucket
            if pending[viewer]?.isEmpty == true { pending[viewer] = nil }
        }
        return out
    }

    // MARK: Foreground connections

    /// Opens a foreground stream for `viewer` (the WebSocket path). The latest stored copy of every share
    /// the viewer is on is replayed first, and anything queued for push is delivered here instead.
    public func connect(_ viewer: ViewerID) -> AsyncStream<RelayEvent> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: RelayEvent.self, bufferingPolicy: .bufferingNewest(configuration.connectionBuffer))
        let id = UUID()
        connections[viewer, default: [:]][id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.disconnect(viewer, id) }
        }
        for share in shares.keys.sorted(by: { $0.raw < $1.raw }) {
            if let copy = latest[share]?[viewer] { continuation.yield(.point(copy)) }
        }
        pending[viewer] = nil
        return stream
    }

    private func disconnect(_ viewer: ViewerID, _ id: UUID) {
        connections[viewer]?[id] = nil
        if connections[viewer]?.isEmpty == true { connections[viewer] = nil }
    }

    // MARK: Queries

    public func presence(of share: ShareID) -> Presence {
        guard let record = shares[share], clock.now() < record.expiresAt else { return .unknownShare }
        guard let seen = record.lastSeen else { return .awaitingFirstPoint }
        return clock.now().elapsed(since: seen) <= configuration.presenceTTL
            ? .online(lastSeen: seen) : .away(lastSeen: seen)
    }

    public func latest(_ share: ShareID, for viewer: ViewerID) -> SealedPoint? { latest[share]?[viewer] }

    public func expiry(of share: ShareID) -> Instant? { shares[share]?.expiresAt }

    public func viewers(of share: ShareID) -> Set<ViewerID> { shares[share]?.viewers ?? [] }

    public var stats: RelayStats {
        RelayStats(activeShares: shares.count,
                   storedPoints: latest.values.reduce(0) { Saturating.add($0, $1.count) },
                   pendingPushes: pending.values.reduce(0) { Saturating.add($0, $1.count) },
                   liveConnections: connections.values.reduce(0) { Saturating.add($0, $1.count) },
                   pushesSent: pushesSent, pushesCoalesced: pushesCoalesced)
    }

    // MARK: Internals

    private func end(_ id: ShareID, reason: EndReason) {
        guard let record = shares.removeValue(forKey: id) else { return }
        latest[id] = nil
        for viewer in record.viewers {
            pending[viewer]?[id] = nil
            if pending[viewer]?.isEmpty == true { pending[viewer] = nil }
            send(.ended(id, reason), to: viewer)
            dropBudgetIfIdle(viewer)
        }
    }

    private func send(_ event: RelayEvent, to viewer: ViewerID) {
        guard let conns = connections[viewer] else { return }
        for c in conns.values { c.yield(event) }
    }

    /// Keeps `pushBudgets` bounded: a viewer on no share has no budget entry.
    /// (Dropping it also resets their burst — acceptable, since a new share is a new conversation.)
    private func dropBudgetIfIdle(_ viewer: ViewerID) {
        guard !shares.values.contains(where: { $0.viewers.contains(viewer) }) else { return }
        pushBudgets[viewer] = nil
    }
}
