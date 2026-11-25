import Foundation

// MARK: - Device conditions

public enum MotionState: String, Sendable, Codable, CaseIterable {
    case stationary, walking, cycling, driving, unknown
}

/// What the sharer's device knows about itself right now. Battery is clamped to 0...1 (NaN reads as 0,
/// i.e. the most conservative cadence), so a bogus sensor value can only make publishing rarer.
public struct DeviceConditions: Hashable, Sendable {
    public let batteryLevel: Double
    public let isLowPowerMode: Bool
    public let isCharging: Bool
    public let motion: MotionState

    public init(batteryLevel: Double, isLowPowerMode: Bool = false, isCharging: Bool = false, motion: MotionState) {
        self.batteryLevel = batteryLevel.isNaN ? 0 : min(1, max(0, batteryLevel))
        self.isLowPowerMode = isLowPowerMode
        self.isCharging = isCharging
        self.motion = motion
    }
}

// MARK: - Cadence

/// How often, and after how much movement, a sharer publishes.
public struct PublishCadence: Hashable, Sendable {
    /// Never publish two movement updates closer together than this.
    public let minInterval: Millis
    /// A movement update needs at least this displacement from the last published point.
    public let minDistanceMeters: Double
    /// Publish even without movement after this long, so the relay's presence TTL never lapses
    /// while the sharer is genuinely online. Always at most half the presence TTL.
    public let heartbeatInterval: Millis
}

/// The adaptive-rate policy: motion picks the base cadence, battery and Low Power Mode stretch it,
/// and the presence TTL caps the heartbeat.
///
/// Trade-off defended in the README: a stationary sharer publishes only heartbeats. Viewers then see
/// "here, as of N seconds ago" instead of a stream of identical points, which is where most of the
/// battery and fan-out cost of a naive 1 Hz publisher goes.
public enum PublishPolicy {
    /// Base cadence per motion state at full battery: (min interval s, min distance m).
    static func base(_ motion: MotionState) -> (interval: Int64, distance: Double) {
        switch motion {
        case .driving: return (5, 50)
        case .cycling: return (10, 25)
        case .walking: return (15, 15)
        case .unknown: return (30, 30)
        // Stationary: movement updates effectively off; heartbeats carry presence.
        case .stationary: return (60, 100)
        }
    }

    /// Battery multiplier: 1× when charging or above 50 %, 2× from 20–50 %, 4× below 20 % or in Low Power Mode.
    static func batteryMultiplier(_ c: DeviceConditions) -> Int64 {
        if c.isCharging { return 1 }
        if c.isLowPowerMode || c.batteryLevel < 0.2 { return 4 }
        if c.batteryLevel < 0.5 { return 2 }
        return 1
    }

    /// The smallest presence TTL the policy (and `RelayConfiguration`) accepts.
    public static let minimumPresenceTTL = Millis.seconds(2)

    /// - Parameter presenceTTL: the relay's presence TTL, clamped to ≥ 2 s exactly as `RelayConfiguration`
    ///   clamps it. The heartbeat is half of it, so one lost heartbeat still arrives within the TTL and
    ///   does not flip the sharer to "away".
    public static func cadence(for c: DeviceConditions, presenceTTL: Millis) -> PublishCadence {
        let b = base(c.motion)
        let k = batteryMultiplier(c)
        let heartbeat = max(minimumPresenceTTL, presenceTTL).dividedBy(2)
        // A movement interval longer than the heartbeat would be meaningless (the heartbeat fires first),
        // so it is capped at the heartbeat.
        let interval = min(Millis.seconds(b.interval).times(k), heartbeat)
        return PublishCadence(minInterval: interval,
                              minDistanceMeters: b.distance * Double(k),
                              heartbeatInterval: heartbeat)
    }
}

// MARK: - Publish gate

public enum PublishReason: String, Sendable, Hashable, Codable {
    case first, moved, heartbeat
}

public enum SuppressReason: String, Sendable, Hashable {
    /// Fix is not newer than the last published one (CoreLocation can redeliver or reorder).
    case outOfOrder
    /// Moved too little since the last published point.
    case notMoved
    /// Inside `minInterval` of the last publish.
    case tooSoon
    /// Accuracy worse than the gate's threshold and no heartbeat is due.
    case inaccurate
    /// The battery budget has no discretionary publishes left; only heartbeats go out.
    case budgetExhausted
}

public enum PublishDecision: Hashable, Sendable {
    case publish(PublishReason)
    case suppress(SuppressReason)

    public var publishes: Bool { if case .publish = self { return true } else { return false } }
}

/// Decides, fix by fix, whether to publish. A value type: the owning session mutates it inside an actor,
/// so there is no shared mutable state to race on.
public struct PublishGate: Sendable {
    public private(set) var lastPublished: LocationFix?
    public private(set) var lastPublishedAt: Instant?
    /// Fixes with an accuracy radius above this are only ever sent as heartbeats.
    public let maxAccuracyMeters: Double

    public init(maxAccuracyMeters: Double = 200) {
        self.maxAccuracyMeters = maxAccuracyMeters.isFinite ? max(0, maxAccuracyMeters) : 200
    }

    /// Pure decision; call `commit` once the caller has actually decided to send.
    /// `discretionaryAllowed` is the battery budget's answer for non-heartbeat publishes.
    public func decide(_ fix: LocationFix, now: Instant, cadence: PublishCadence,
                       discretionaryAllowed: Bool = true) -> PublishDecision {
        guard let last = lastPublished, let lastAt = lastPublishedAt else { return .publish(.first) }
        if fix.timestamp <= last.timestamp { return .suppress(.outOfOrder) }
        let elapsed = now.elapsed(since: lastAt)
        // Heartbeat first: it is what keeps presence alive, so neither accuracy nor budget can block it.
        if elapsed >= cadence.heartbeatInterval { return .publish(.heartbeat) }
        if fix.accuracyMeters > maxAccuracyMeters { return .suppress(.inaccurate) }
        if elapsed < cadence.minInterval { return .suppress(.tooSoon) }
        if fix.distance(to: last) < cadence.minDistanceMeters { return .suppress(.notMoved) }
        return discretionaryAllowed ? .publish(.moved) : .suppress(.budgetExhausted)
    }

    /// True when a heartbeat is owed even though no new fix arrived (CoreLocation goes quiet when the
    /// device stops moving). The session then re-publishes the last fix with a fresh `sentAt`.
    public func heartbeatDue(now: Instant, cadence: PublishCadence) -> Bool {
        guard let lastAt = lastPublishedAt else { return false }
        return now.elapsed(since: lastAt) >= cadence.heartbeatInterval
    }

    public mutating func commit(_ fix: LocationFix, at now: Instant) {
        lastPublished = fix
        lastPublishedAt = now
    }
}

// MARK: - Token bucket

/// A refilling token bucket: `capacity` tokens, one more every `refillEvery`. Used twice — as the
/// sharer's per-session battery budget and as the relay's per-viewer push budget.
public struct TokenBucket: Sendable, Hashable {
    public let capacity: Int
    public let refillEvery: Millis
    public private(set) var tokens: Int
    private var lastRefill: Instant

    /// `capacity` is clamped to ≥ 1 and `refillEvery` to ≥ 1 ms, so the bucket can never divide by zero
    /// or be permanently empty by construction.
    public init(capacity: Int, refillEvery: Millis, now: Instant) {
        self.capacity = max(1, capacity)
        self.refillEvery = max(Millis(1), refillEvery)
        self.tokens = self.capacity
        self.lastRefill = now
    }

    public mutating func refill(now: Instant) {
        // A clock that steps backwards yields zero elapsed (see `Instant.elapsed`): no refill, no trap.
        let elapsed = now.elapsed(since: lastRefill)
        let earned = elapsed.value / refillEvery.value          // refillEvery ≥ 1, so never ÷0
        guard earned > 0 else {
            if now < lastRefill { lastRefill = now }            // re-anchor after a backwards step
            return
        }
        let room = Int64(capacity - tokens)
        tokens += Int(min(earned, room))
        // Keep the remainder so refill is exact over many calls; jump ahead when the bucket is full.
        lastRefill = tokens == capacity ? now
            : lastRefill.adding(refillEvery.times(earned))
    }

    /// Takes one token if available.
    public mutating func tryTake(now: Instant) -> Bool {
        refill(now: now)
        guard tokens > 0 else { return false }
        tokens -= 1
        return true
    }

    /// When the next token becomes available (now, if one is already there).
    public func nextTokenAt(now: Instant) -> Instant {
        tokens > 0 ? now : lastRefill.adding(refillEvery)
    }
}
