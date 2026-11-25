import Foundation

// MARK: - Saturating arithmetic

/// Overflow-free integer arithmetic. Every duration and counter in this package goes through these
/// helpers, so no public input can trap the process with `+`, `*` or `Int(Double)`.
public enum Saturating {
    public static func add<T: FixedWidthInteger>(_ a: T, _ b: T) -> T {
        let (r, overflow) = a.addingReportingOverflow(b)
        guard overflow else { return r }
        return b > 0 ? T.max : T.min
    }

    public static func subtract<T: FixedWidthInteger>(_ a: T, _ b: T) -> T {
        let (r, overflow) = a.subtractingReportingOverflow(b)
        guard overflow else { return r }
        return b > 0 ? T.min : T.max
    }

    public static func multiply<T: FixedWidthInteger>(_ a: T, _ b: T) -> T {
        let (r, overflow) = a.multipliedReportingOverflow(by: b)
        guard overflow else { return r }
        return (a < 0) != (b < 0) ? T.min : T.max
    }

    /// `Int64(Double)` traps on NaN, infinity and out-of-range values. This never does:
    /// NaN maps to 0 and anything outside the representable range clamps to the nearest bound.
    public static func int64(_ d: Double) -> Int64 {
        guard d.isFinite else { return d.isNaN ? 0 : (d > 0 ? .max : .min) }
        // Double(Int64.max) rounds up to 2^63, which is not representable, so `>=` is the correct test.
        if d >= Double(Int64.max) { return .max }
        if d <= Double(Int64.min) { return .min }
        return Int64(d)
    }

    /// Same contract as `int64(_:)`, for the platform `Int`. The ceiling is derived from `Int.max`,
    /// never hard-coded, so it is correct on 32-bit targets too.
    public static func int(_ d: Double) -> Int {
        guard d.isFinite else { return d.isNaN ? 0 : (d > 0 ? .max : .min) }
        if d >= Double(Int.max) { return .max }
        if d <= Double(Int.min) { return .min }
        return Int(d)
    }
}

// MARK: - Time

/// A point in time in whole milliseconds. Integer time keeps every comparison exact and every
/// arithmetic step saturating; there is no floating-point drift in TTL or budget maths.
public struct Instant: Comparable, Hashable, Sendable, Codable, CustomStringConvertible {
    public let millis: Int64
    public init(millis: Int64) { self.millis = millis }

    public static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.millis < rhs.millis }

    public func adding(_ d: Millis) -> Instant { Instant(millis: Saturating.add(millis, d.value)) }

    /// Elapsed time from `earlier` to `self`. Never negative: a clock that steps backwards reads as zero
    /// elapsed rather than as a huge negative age.
    public func elapsed(since earlier: Instant) -> Millis {
        Millis(max(0, Saturating.subtract(millis, earlier.millis)))
    }

    public var description: String { "t+\(millis)ms" }
}

/// A non-negative duration in milliseconds. Negative input clamps to zero.
public struct Millis: Comparable, Hashable, Sendable, Codable, CustomStringConvertible {
    public let value: Int64
    public init(_ value: Int64) { self.value = max(0, value) }

    public static func seconds(_ s: Int64) -> Millis { Millis(Saturating.multiply(s, 1_000)) }
    public static func minutes(_ m: Int64) -> Millis { Millis(Saturating.multiply(m, 60_000)) }
    public static func hours(_ h: Int64) -> Millis { Millis(Saturating.multiply(h, 3_600_000)) }
    public static let zero = Millis(0)

    public static func < (lhs: Millis, rhs: Millis) -> Bool { lhs.value < rhs.value }

    /// Decoding goes through the clamping initialiser, so JSON cannot produce a negative duration.
    public init(from decoder: Decoder) throws {
        self.init(try decoder.singleValueContainer().decode(Int64.self))
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(value)
    }

    public func times(_ k: Int64) -> Millis { Millis(Saturating.multiply(value, k)) }
    public func dividedBy(_ k: Int64) -> Millis { k > 0 ? Millis(value / k) : self }

    public var seconds: Double { Double(value) / 1_000 }
    public var description: String { "\(value)ms" }
}

/// Injected time source. Production code uses `SystemClock`; tests and the demo use `ManualClock`
/// so every TTL, budget and expiry is deterministic.
public protocol LiveClock: Sendable {
    func now() -> Instant
}

public struct SystemClock: LiveClock {
    public init() {}
    public func now() -> Instant {
        Instant(millis: Saturating.int64(Date().timeIntervalSince1970 * 1_000))
    }
}

/// A clock that only moves when told to. Lock-protected so it can be shared across actors.
public final class ManualClock: LiveClock, @unchecked Sendable {
    // @unchecked: all mutable state is guarded by `lock`.
    private let lock = NSLock()
    private var current: Instant

    public init(start: Instant = Instant(millis: 0)) { current = start }

    public func now() -> Instant { lock.withLock { current } }

    public func advance(by d: Millis) {
        lock.withLock { current = current.adding(d) }
    }
}

// MARK: - Identifiers

public struct ShareID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let raw: String
    public init(_ raw: String) { self.raw = raw }
    public var description: String { raw }
}

public struct ViewerID: Hashable, Sendable, Codable, Comparable, CustomStringConvertible {
    public let raw: String
    public init(_ raw: String) { self.raw = raw }
    public static func < (lhs: ViewerID, rhs: ViewerID) -> Bool { lhs.raw < rhs.raw }
    public var description: String { raw }
}

// MARK: - Location fix

/// One validated GPS fix. Construction fails for NaN, out-of-range coordinates or a negative/NaN accuracy,
/// so nothing downstream ever has to re-check.
public struct LocationFix: Hashable, Sendable, Codable {
    public let latitude: Double
    public let longitude: Double
    /// Horizontal accuracy radius in metres (CoreLocation semantics: smaller is better).
    public let accuracyMeters: Double
    public let timestamp: Instant

    public init?(latitude: Double, longitude: Double, accuracyMeters: Double, timestamp: Instant) {
        guard latitude.isFinite, longitude.isFinite, accuracyMeters.isFinite,
              (-90.0...90.0).contains(latitude), (-180.0...180.0).contains(longitude),
              accuracyMeters >= 0 else { return nil }
        self.latitude = latitude
        self.longitude = longitude
        self.accuracyMeters = accuracyMeters
        self.timestamp = timestamp
    }

    private enum CodingKeys: String, CodingKey { case latitude, longitude, accuracyMeters, timestamp }

    /// Decoding goes through the validating initialiser, so JSON cannot smuggle in an invalid fix.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let fix = LocationFix(latitude: try c.decode(Double.self, forKey: .latitude),
                                    longitude: try c.decode(Double.self, forKey: .longitude),
                                    accuracyMeters: try c.decode(Double.self, forKey: .accuracyMeters),
                                    timestamp: try c.decode(Instant.self, forKey: .timestamp))
        else { throw DecodingError.dataCorrupted(.init(codingPath: c.codingPath, debugDescription: "invalid location fix")) }
        self = fix
    }

    /// Great-circle distance in metres (haversine). Always finite and non-negative for valid fixes.
    public func distance(to other: LocationFix) -> Double {
        let r = 6_371_000.0
        let φ1 = latitude * .pi / 180, φ2 = other.latitude * .pi / 180
        let dφ = (other.latitude - latitude) * .pi / 180
        let dλ = (other.longitude - longitude) * .pi / 180
        let a = sin(dφ / 2) * sin(dφ / 2) + cos(φ1) * cos(φ2) * sin(dλ / 2) * sin(dλ / 2)
        // Clamp: rounding can push `a` a hair outside [0, 1], which would make sqrt/atan2 return NaN.
        let clamped = min(1, max(0, a))
        return 2 * r * atan2(clamped.squareRoot(), (1 - clamped).squareRoot())
    }
}
