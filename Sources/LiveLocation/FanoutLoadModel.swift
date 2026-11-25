import Foundation

/// Inputs to the back-of-envelope capacity estimate. Every value is sanitised on the way in
/// (NaN/negative → 0, fractions clamped to 0...1), so the model always returns finite numbers.
public struct LoadAssumptions: Sendable, Hashable {
    public let activeShares: Int
    public let meanViewersPerShare: Double
    /// Fraction of sharers in each motion state. Normalised; an all-zero mix is treated as `.unknown`.
    public let motionMix: [MotionState: Double]
    /// Fraction of viewers with the app in the foreground (WebSocket); the rest are background (push).
    public let foregroundFraction: Double
    public let copyBytes: Int
    public let presenceTTL: Millis
    /// Sustained push budget per background viewer, as the relay enforces it.
    public let pushRefill: Millis

    public init(activeShares: Int, meanViewersPerShare: Double, motionMix: [MotionState: Double],
                foregroundFraction: Double, copyBytes: Int, presenceTTL: Millis, pushRefill: Millis) {
        self.activeShares = max(0, activeShares)
        self.meanViewersPerShare = Self.nonNegative(meanViewersPerShare)
        self.motionMix = motionMix.mapValues(Self.nonNegative)
        self.foregroundFraction = min(1, Self.nonNegative(foregroundFraction))
        self.copyBytes = max(0, copyBytes)
        self.presenceTTL = presenceTTL
        self.pushRefill = max(Millis(1), pushRefill)
    }

    static func nonNegative(_ d: Double) -> Double { d.isFinite && d > 0 ? d : 0 }

    /// N active shares (1,000 by default), 3 viewers each, a commuting-hour mix, 30 % of viewers foregrounded.
    public static func reference(copyBytes: Int, activeShares: Int = 1_000,
                                 pushRefill: Millis = .minutes(5)) -> LoadAssumptions {
        LoadAssumptions(activeShares: activeShares, meanViewersPerShare: 3,
                        motionMix: [.stationary: 0.55, .walking: 0.2, .cycling: 0.05, .driving: 0.2],
                        foregroundFraction: 0.3, copyBytes: copyBytes,
                        presenceTTL: .seconds(120), pushRefill: pushRefill)
    }
}

public struct LoadEstimate: Sendable, Hashable {
    /// Sharer → relay requests per second.
    public let publishesPerSecond: Double
    /// Sealed copies the relay accepts per second (publishes × viewers): the real fan-out cost.
    public let copiesPerSecond: Double
    public let socketMessagesPerSecond: Double
    /// Background pushes per hour if every background copy became a push.
    public let pushesPerHourUnbudgeted: Double
    /// …and with the relay's per-viewer budget and coalescing.
    public let pushesPerHourBudgeted: Double
    public let ingressBytesPerSecond: Double
    /// Latest-only storage: one copy per (share, viewer).
    public let storedBytes: Int
    /// The same population publishing at a naive 1 Hz.
    public let naiveCopiesPerSecond: Double
    /// Open foreground connections (WebSocket) the fleet must hold.
    public let foregroundConnections: Double
    /// Background viewers reachable only by push.
    public let backgroundViewers: Double
}

/// Capacity per N active shares under `PublishPolicy` at full battery (the worst case for load: low
/// battery only lowers it). Assumes moving sharers move enough to clear the distance threshold every
/// interval, which over-estimates — the right direction for a capacity plan.
public enum FanoutLoadModel {
    public static func estimate(_ a: LoadAssumptions) -> LoadEstimate {
        let total = a.motionMix.values.reduce(0, +)
        let mix: [MotionState: Double] = total > 0 ? a.motionMix.mapValues { $0 / total } : [.unknown: 1]
        var perSharerHz = 0.0
        for (state, share) in mix {
            let c = PublishPolicy.cadence(for: DeviceConditions(batteryLevel: 1, isCharging: true, motion: state),
                                          presenceTTL: a.presenceTTL)
            // Stationary sharers send only heartbeats; moving ones send at their movement interval.
            let period = state == .stationary ? c.heartbeatInterval.seconds : c.minInterval.seconds
            perSharerHz += share * (period > 0 ? 1 / period : 0)
        }

        let shares = Double(a.activeShares)
        let publishes = shares * perSharerHz
        let copies = publishes * a.meanViewersPerShare
        let socket = copies * a.foregroundFraction
        let foregroundConnections = shares * a.meanViewersPerShare * a.foregroundFraction
        let backgroundViewers = shares * a.meanViewersPerShare * (1 - a.foregroundFraction)
        let perViewerPushHz = perSharerHz
        let budgetHz = 1 / max(0.001, a.pushRefill.seconds)
        let pushesUnbudgeted = backgroundViewers * perViewerPushHz * 3_600
        let pushesBudgeted = backgroundViewers * min(perViewerPushHz, budgetHz) * 3_600
        let stored = Saturating.int(shares * a.meanViewersPerShare * Double(a.copyBytes))

        return LoadEstimate(publishesPerSecond: finite(publishes), copiesPerSecond: finite(copies),
                            socketMessagesPerSecond: finite(socket),
                            pushesPerHourUnbudgeted: finite(pushesUnbudgeted),
                            pushesPerHourBudgeted: finite(pushesBudgeted),
                            ingressBytesPerSecond: finite(copies * Double(a.copyBytes)),
                            storedBytes: max(0, stored),
                            naiveCopiesPerSecond: finite(shares * a.meanViewersPerShare),
                            foregroundConnections: finite(foregroundConnections),
                            backgroundViewers: finite(backgroundViewers))
    }

    /// NaN → 0; ±∞ clamps to the largest finite value, so an overflowing input never reads as "no load".
    private static func finite(_ d: Double) -> Double { d.isNaN ? 0 : min(max(d, 0), .greatestFiniteMagnitude) }
}
