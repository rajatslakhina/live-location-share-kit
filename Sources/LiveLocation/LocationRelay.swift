import Foundation

public struct RelayConfiguration: Sendable, Hashable {
    /// A share with no accepted copy for this long reads as `.away`. Clamped to ≥ 2 s, so the sharer's
    /// heartbeat (`PublishPolicy`: TTL / 2) is always at most half of it. Immutable after `init`, so the
    /// clamps cannot be undone.
    public let presenceTTL: Millis
    /// Upper bound on any share's lifetime. "Share until I stop" is still capped; nothing is forever.
    public let maxShareDuration: Millis
    public let maxViewersPerShare: Int
    public let maxActiveShares: Int
    /// Per-viewer push budget (background delivery): burst of `pushBurst`, then one per `pushRefill`.
    public let pushBurst: Int
    public let pushRefill: Millis
    /// Per-connection point buffer. A slow foreground consumer drops its *oldest points*, never blocks the
    /// relay. Control events (revoked / ended) travel on a separate stream and are not dropped this way.
    public let connectionBuffer: Int
    /// Open foreground connections allowed per viewer (devices/tabs). Bounds connection memory.
    public let maxConnectionsPerViewer: Int

    public init(presenceTTL: Millis = .seconds(120), maxShareDuration: Millis = .hours(24),
                maxViewersPerShare: Int = 50, maxActiveShares: Int = 10_000,
                pushBurst: Int = 4, pushRefill: Millis = .minutes(5), connectionBuffer: Int = 32,
                maxConnectionsPerViewer: Int = 4) {
        self.presenceTTL = max(Millis.seconds(2), presenceTTL)
        self.maxShareDuration = max(Millis.seconds(1), maxShareDuration)
        self.maxViewersPerShare = max(1, maxViewersPerShare)
        self.maxActiveShares = max(1, maxActiveShares)
        self.pushBurst = max(1, pushBurst)
        self.pushRefill = max(Millis(1), pushRefill)
        self.connectionBuffer = max(1, connectionBuffer)
        self.maxConnectionsPerViewer = max(1, maxConnectionsPerViewer)
    }
}

public enum EndReason: String, Sendable, Hashable { case expired, stopped }

/// Share-level events for a connected viewer. Kept off the point stream so a burst of points can never
/// evict "remove this pin".
public enum ControlEvent: Sendable, Hashable {
    case revoked(ShareID)
    case ended(ShareID, EndReason)
}

/// A foreground connection (the WebSocket path): newest-wins points plus a separate control stream.
public struct RelayConnection: Sendable {
    public let points: AsyncStream<SealedPoint>
    public let control: AsyncStream<ControlEvent>
}

public enum RelayError: Error, Equatable, Sendable {
    case invalidDuration
    case noViewers
    case tooManyViewers(limit: Int)
    case capacityReached(limit: Int)
    case duplicateShare
    case unknownShare
    /// `connect` for a viewer who is on no share.
    case notAViewer
    case tooManyConnections(limit: Int)
}

public enum RejectReason: String, Sendable, Hashable {
    case unknownShare, shareExpired, notARecipient, staleSequence
    /// The sequence is beyond anything a real sharer could have reached by now (see
    /// `LocationRelay.maxSequenceLead`). Stops a single junk copy at `UInt64.max` from locking a share.
    case futureSequence
}

/// The relay's answer to one batch. A batch is one point for one share (that is how `SharerSession`
/// uploads), so `rejected` is keyed by viewer.
public struct PublishReceipt: Sendable, Hashable {
    public internal(set) var deliveredLive: [ViewerID] = []
    public internal(set) var queuedForPush: [ViewerID] = []
    public internal(set) var rejected: [ViewerID: RejectReason] = [:]
    public init() {}

    /// True when at least one copy was accepted.
    public var accepted: Bool { !deliveredLive.isEmpty || !queuedForPush.isEmpty }

    /// True when nothing was accepted and every rejection says the share no longer exists — the sharer
    /// should stop publishing.
    public var shareIsGone: Bool {
        deliveredLive.isEmpty && queuedForPush.isEmpty && !rejected.isEmpty
            && rejected.values.allSatisfy { $0 == .unknownShare || $0 == .shareExpired }
    }
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
    public let pushBudgets: Int
}

/// The server half of the system, modelled as one actor: presence with a TTL, **only the latest copy per
/// (share, viewer)**, time- and revocation-based expiry, foreground fan-out over a stream (the WebSocket
/// path) and budgeted, coalescing background pushes (the Live Activity path).
///
/// Every method is synchronous inside the actor — there is no `await` between reading and writing state,
/// so there is no actor-reentrancy window. Storage is bounded by `maxActiveShares × maxViewersPerShare`,
/// connections by `maxConnectionsPerViewer` per viewer (closed when the viewer leaves their last share),
/// and push budgets by viewers seen within one full refill.
/// Housekeeping: `sweep()` is O(1) until an expiry is due, then O(shares); per-viewer cleanup uses a
/// viewer → shares index instead of scanning every share.
public actor LocationRelay {
    struct ShareRecord {
        var viewers: Set<ViewerID>
        let expiresAt: Instant
        var lastSeen: Instant?
    }
    struct Pending {
        var sealed: SealedPoint
        var coalesced: Int
        /// When the oldest undelivered point for this (viewer, share) arrived. Kept across coalescing so
        /// the push queue is served oldest-first and a busy share cannot starve a quiet one.
        let waitingSince: Instant
    }
    struct Connection {
        let points: AsyncStream<SealedPoint>.Continuation
        let control: AsyncStream<ControlEvent>.Continuation
    }

    /// Control backlog per connection. Each share produces at most one `revoked` and one `ended` per viewer,
    /// so this is only reached by a consumer that never reads; it then keeps the newest events.
    public static let controlBuffer = 1_024
    /// How far ahead of the relay's clock a sharer's epoch sequence (`SharerSession.epochSequence`) may be.
    /// Bounds clock skew between devices; anything further ahead is rejected as `.futureSequence`.
    public static let maxSequenceLead = Millis.minutes(5)

    public nonisolated let configuration: RelayConfiguration
    private let clock: any LiveClock

    private var shares: [ShareID: ShareRecord] = [:]
    private var viewerShares: [ViewerID: Set<ShareID>] = [:]
    private var earliestExpiry: Instant?
    private var latest: [ShareID: [ViewerID: SealedPoint]] = [:]
    private var pending: [ViewerID: [ShareID: Pending]] = [:]
    private var pushBudgets: [ViewerID: TokenBucket] = [:]
    private var connections: [ViewerID: [UUID: Connection]] = [:]
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
        _ = sweep()                                   // an expired-but-unswept id is free to reuse
        guard shares[id] == nil else { throw RelayError.duplicateShare }
        guard shares.count < configuration.maxActiveShares else {
            throw RelayError.capacityReached(limit: configuration.maxActiveShares)
        }
        let expiresAt = clock.now().adding(duration)
        shares[id] = ShareRecord(viewers: viewers, expiresAt: expiresAt, lastSeen: nil)
        for v in viewers { viewerShares[v, default: []].insert(id) }
        earliestExpiry = min(earliestExpiry ?? expiresAt, expiresAt)
        return expiresAt
    }

    /// Adds a viewer to a running share. The sharer must also call `SharerSession.addViewer` so the next
    /// point is sealed for them.
    public func addViewer(_ viewer: ViewerID, to share: ShareID) throws {
        _ = sweep()
        guard var record = shares[share] else { throw RelayError.unknownShare }
        guard record.viewers.contains(viewer) || record.viewers.count < configuration.maxViewersPerShare else {
            throw RelayError.tooManyViewers(limit: configuration.maxViewersPerShare)
        }
        record.viewers.insert(viewer)
        shares[share] = record
        viewerShares[viewer, default: []].insert(share)
    }

    /// Removes one viewer: their stored copy and queued push are deleted immediately and their open
    /// connections get `.revoked`. The sharer's device stops sealing for them too (`PerViewerSealer.revoke`),
    /// so this is defence in depth, not the only line.
    public func revoke(_ viewer: ViewerID, from share: ShareID) {
        guard shares[share]?.viewers.remove(viewer) != nil else { return }
        send(.revoked(share), to: viewer)                // before detach: it may close the connection
        detach(viewer, from: share)
    }

    public func stopShare(_ id: ShareID) { end(id, reason: .stopped) }

    /// Ends every share whose expiry has passed. Called on each start and publish, and by a timer in a
    /// real server; idempotent. O(1) unless the earliest expiry is due.
    @discardableResult
    public func sweep() -> [ShareID] {
        let now = clock.now()
        guard let due = earliestExpiry, now >= due else { return [] }
        let expired = shares.filter { now >= $0.value.expiresAt }.keys.sorted { $0.raw < $1.raw }
        for id in expired { end(id, reason: .expired) }
        earliestExpiry = shares.values.map(\.expiresAt).min()
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
            // Unreachable after `sweep()` with the same clock reading; kept as a guard for clocks that
            // move between the two reads.
            guard now < record.expiresAt else { receipt.rejected[copy.viewerID] = .shareExpired; continue }
            guard record.viewers.contains(copy.viewerID) else {
                receipt.rejected[copy.viewerID] = .notARecipient
                continue
            }
            guard copy.sequence <= SharerSession.epochSequence(now.adding(Self.maxSequenceLead)) else {
                receipt.rejected[copy.viewerID] = .futureSequence
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
                for c in conns.values { c.points.yield(copy) }
                receipt.deliveredLive.append(copy.viewerID)
            } else {
                enqueuePush(copy, now: now)
                receipt.queuedForPush.append(copy.viewerID)
            }
        }
        return receipt
    }

    private func enqueuePush(_ copy: SealedPoint, now: Instant) {
        if let existing = pending[copy.viewerID]?[copy.shareID] {
            pending[copy.viewerID]?[copy.shareID] = Pending(sealed: copy, coalesced: Saturating.add(existing.coalesced, 1),
                                                            waitingSince: existing.waitingSince)
            pushesCoalesced = Saturating.add(pushesCoalesced, 1)
        } else {
            pending[copy.viewerID, default: [:]][copy.shareID] = Pending(sealed: copy, coalesced: 0, waitingSince: now)
        }
    }

    /// Hands every pending push that has budget to the caller (the APNs sender). Each viewer's queue is
    /// served oldest-waiting first. Pushes without budget stay queued — coalesced to the newest point —
    /// until a token refills.
    public func drainPushes() -> [PushDelivery] {
        let now = clock.now()
        var out: [PushDelivery] = []
        for viewer in pending.keys.sorted() {
            guard let queue = pending[viewer] else { continue }
            var bucket = pushBudgets[viewer]
                ?? TokenBucket(capacity: configuration.pushBurst, refillEvery: configuration.pushRefill, now: now)
            let order = queue.sorted { ($0.value.waitingSince, $0.key.raw) < ($1.value.waitingSince, $1.key.raw) }
            for (share, item) in order {
                guard bucket.tryTake(now: now) else { break }
                out.append(PushDelivery(viewer: viewer, sealed: item.sealed, coalesced: item.coalesced))
                pending[viewer]?[share] = nil
                pushesSent = Saturating.add(pushesSent, 1)
            }
            pushBudgets[viewer] = bucket
            if pending[viewer]?.isEmpty == true { pending[viewer] = nil }
        }
        // Drop budgets of viewers on no share once they have fully refilled (nothing left to protect).
        for (viewer, var bucket) in pushBudgets where viewerShares[viewer] == nil {
            bucket.refill(now: now)
            if bucket.tokens == bucket.capacity { pushBudgets[viewer] = nil }
        }
        return out
    }

    // MARK: Foreground connections

    /// Opens a foreground connection for `viewer` (the WebSocket path). The latest stored copy of every
    /// share the viewer is on is replayed first, and anything queued for push is delivered here instead.
    /// A reconnecting viewer reconciles pins for shares that ended while it was away with `shares(for:)`.
    /// Throws `notAViewer` for a viewer on no share and `tooManyConnections` past the per-viewer cap.
    public func connect(_ viewer: ViewerID) throws -> RelayConnection {
        _ = sweep()
        guard viewerShares[viewer]?.isEmpty == false else { throw RelayError.notAViewer }
        guard (connections[viewer]?.count ?? 0) < configuration.maxConnectionsPerViewer else {
            throw RelayError.tooManyConnections(limit: configuration.maxConnectionsPerViewer)
        }
        let (points, pointsCont) = AsyncStream.makeStream(
            of: SealedPoint.self, bufferingPolicy: .bufferingNewest(configuration.connectionBuffer))
        let (control, controlCont) = AsyncStream.makeStream(
            of: ControlEvent.self, bufferingPolicy: .bufferingNewest(Self.controlBuffer))
        let id = UUID()
        connections[viewer, default: [:]][id] = Connection(points: pointsCont, control: controlCont)
        // Terminating either stream (consumer cancelled or dropped) closes the connection.
        pointsCont.onTermination = { [weak self] _ in Task { await self?.disconnect(viewer, id) } }
        controlCont.onTermination = { [weak self] _ in Task { await self?.disconnect(viewer, id) } }
        for share in (viewerShares[viewer] ?? []).sorted(by: { $0.raw < $1.raw }) {
            if let copy = latest[share]?[viewer] { pointsCont.yield(copy) }
        }
        pending[viewer] = nil
        return RelayConnection(points: points, control: control)
    }

    private func disconnect(_ viewer: ViewerID, _ id: UUID) {
        guard let conn = connections[viewer]?.removeValue(forKey: id) else { return }
        conn.points.finish()
        conn.control.finish()
        if connections[viewer]?.isEmpty == true { connections[viewer] = nil }
    }

    // MARK: Queries

    public func presence(of share: ShareID) -> Presence {
        let now = clock.now()
        guard let record = shares[share], now < record.expiresAt else { return .unknownShare }
        guard let seen = record.lastSeen else { return .awaitingFirstPoint }
        return now.elapsed(since: seen) <= configuration.presenceTTL ? .online(lastSeen: seen) : .away(lastSeen: seen)
    }

    public func latest(_ share: ShareID, for viewer: ViewerID) -> SealedPoint? { latest[share]?[viewer] }

    public func expiry(of share: ShareID) -> Instant? { shares[share]?.expiresAt }

    public func viewers(of share: ShareID) -> Set<ViewerID> { shares[share]?.viewers ?? [] }

    /// The shares a viewer is currently on.
    public func shares(for viewer: ViewerID) -> Set<ShareID> { viewerShares[viewer] ?? [] }

    public var stats: RelayStats {
        RelayStats(activeShares: shares.count,
                   storedPoints: latest.values.reduce(0) { Saturating.add($0, $1.count) },
                   pendingPushes: pending.values.reduce(0) { Saturating.add($0, $1.count) },
                   liveConnections: connections.values.reduce(0) { Saturating.add($0, $1.count) },
                   pushesSent: pushesSent, pushesCoalesced: pushesCoalesced,
                   pushBudgets: pushBudgets.count)
    }

    // MARK: Internals

    private func end(_ id: ShareID, reason: EndReason) {
        guard let record = shares.removeValue(forKey: id) else { return }
        latest[id] = nil
        for viewer in record.viewers {
            send(.ended(id, reason), to: viewer)           // before detach: it may close the connection
            detach(viewer, from: id)
        }
    }

    /// Removes every per-(viewer, share) trace. A viewer left on no share has their connections closed
    /// (already-yielded events are still delivered). Their push budget is kept until it has fully
    /// refilled — so revoking and re-adding cannot reset a viewer's burst — and then dropped by
    /// `drainPushes`, which keeps `pushBudgets` bounded.
    private func detach(_ viewer: ViewerID, from share: ShareID) {
        latest[share]?[viewer] = nil
        pending[viewer]?[share] = nil
        if pending[viewer]?.isEmpty == true { pending[viewer] = nil }
        viewerShares[viewer]?.remove(share)
        if viewerShares[viewer]?.isEmpty == true {
            viewerShares[viewer] = nil
            if let conns = connections.removeValue(forKey: viewer) {
                for c in conns.values { c.points.finish(); c.control.finish() }
            }
        }
    }

    private func send(_ event: ControlEvent, to viewer: ViewerID) {
        guard let conns = connections[viewer] else { return }
        for c in conns.values { c.control.yield(event) }
    }
}
