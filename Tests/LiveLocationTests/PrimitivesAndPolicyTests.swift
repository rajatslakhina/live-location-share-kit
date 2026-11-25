import XCTest
@testable import LiveLocation

final class SaturatingAndTimeTests: XCTestCase {
    func testAddMultiplySubtractSaturateInsteadOfTrapping() {
        XCTAssertEqual(Saturating.add(Int64.max, 1), .max)
        XCTAssertEqual(Saturating.add(Int64.min, -1), .min)
        XCTAssertEqual(Saturating.subtract(Int64.min, 1), .min)
        XCTAssertEqual(Saturating.subtract(Int64.max, -1), .max)
        XCTAssertEqual(Saturating.multiply(Int64.max, 2), .max)
        XCTAssertEqual(Saturating.multiply(Int64.max, -2), .min)
        XCTAssertEqual(Saturating.multiply(Int.min, -1), .max)
        XCTAssertEqual(Saturating.add(2, 3), 5)
    }

    func testDoubleToIntegerNeverTraps() {
        XCTAssertEqual(Saturating.int64(.nan), 0)
        XCTAssertEqual(Saturating.int64(.infinity), .max)
        XCTAssertEqual(Saturating.int64(-.infinity), .min)
        XCTAssertEqual(Saturating.int64(1e300), .max)
        XCTAssertEqual(Saturating.int64(-1e300), .min)
        XCTAssertEqual(Saturating.int64(9_223_372_036_854_775_808.0), .max)   // exactly 2^63
        XCTAssertEqual(Saturating.int(.nan), 0)
        XCTAssertEqual(Saturating.int(1e300), .max)
        XCTAssertEqual(Saturating.int(-3.9), -3)
    }

    func testMillisClampsNegativeAndInstantElapsedNeverGoesNegative() {
        XCTAssertEqual(Millis(-5).value, 0)
        XCTAssertEqual(Millis.hours(Int64.max).value, .max)
        let a = Instant(millis: 1_000), b = Instant(millis: 400)
        XCTAssertEqual(b.elapsed(since: a), .zero, "a clock stepping backwards reads as zero elapsed")
        XCTAssertEqual(a.elapsed(since: b).value, 600)
        XCTAssertEqual(Instant(millis: .max).adding(.seconds(1)).millis, .max)
        XCTAssertEqual(Instant(millis: .min).elapsed(since: Instant(millis: .max)), .zero)
        XCTAssertEqual(Millis(10).dividedBy(0).value, 10, "division by zero returns the input instead of trapping")
    }

    func testLocationFixRejectsInvalidInput() {
        let t = Instant(millis: 0)
        XCTAssertNil(LocationFix(latitude: .nan, longitude: 0, accuracyMeters: 5, timestamp: t))
        XCTAssertNil(LocationFix(latitude: 91, longitude: 0, accuracyMeters: 5, timestamp: t))
        XCTAssertNil(LocationFix(latitude: 0, longitude: -180.5, accuracyMeters: 5, timestamp: t))
        XCTAssertNil(LocationFix(latitude: 0, longitude: 0, accuracyMeters: -1, timestamp: t), "CoreLocation's 'invalid' marker")
        XCTAssertNil(LocationFix(latitude: 0, longitude: 0, accuracyMeters: .infinity, timestamp: t))
        XCTAssertNotNil(LocationFix(latitude: 90, longitude: 180, accuracyMeters: 0, timestamp: t))
    }

    func testDecodingCannotSmuggleInInvalidValues() throws {
        let bad = #"{"latitude":500,"longitude":0,"accuracyMeters":5,"timestamp":{"millis":0}}"#
        XCTAssertThrowsError(try JSONDecoder().decode(LocationFix.self, from: Data(bad.utf8)))
        let good = #"{"latitude":12.5,"longitude":0,"accuracyMeters":5,"timestamp":{"millis":0}}"#
        XCTAssertEqual(try JSONDecoder().decode(LocationFix.self, from: Data(good.utf8)).latitude, 12.5)
        XCTAssertEqual(try JSONDecoder().decode(Millis.self, from: Data("-40".utf8)).value, 0)
        let fix = try XCTUnwrap(LocationFix(latitude: 1, longitude: 2, accuracyMeters: 3, timestamp: Instant(millis: 4)))
        XCTAssertEqual(try JSONDecoder().decode(LocationFix.self, from: JSONEncoder().encode(fix)), fix)
    }

    func testHaversineMatchesKnownDistances() throws {
        let t = Instant(millis: 0)
        let a = try XCTUnwrap(LocationFix(latitude: 0, longitude: 0, accuracyMeters: 5, timestamp: t))
        let b = try XCTUnwrap(LocationFix(latitude: 1, longitude: 0, accuracyMeters: 5, timestamp: t))
        XCTAssertEqual(a.distance(to: b), 111_195, accuracy: 5, "one degree of latitude on a 6371 km sphere")
        XCTAssertEqual(a.distance(to: a), 0)
        let antipode = try XCTUnwrap(LocationFix(latitude: 0, longitude: 180, accuracyMeters: 5, timestamp: t))
        let d = a.distance(to: antipode)
        XCTAssertTrue(d.isFinite)
        XCTAssertEqual(d, .pi * 6_371_000, accuracy: 1)
    }
}

final class PublishPolicyTests: XCTestCase {
    let ttl = Millis.seconds(120)

    func testHeartbeatIsAtMostHalfThePresenceTTLForEveryCondition() {
        for motion in MotionState.allCases {
            for battery in [0.0, 0.1, 0.3, 0.6, 1.0, .nan] {
                for lowPower in [false, true] {
                    for ttl in [Millis(1), .seconds(1), .seconds(3), .seconds(120), .hours(1)] {
                        let c = PublishPolicy.cadence(for: DeviceConditions(batteryLevel: battery, isLowPowerMode: lowPower, motion: motion),
                                                      presenceTTL: ttl)
                        // TTLs below 2 s are clamped to 2 s, exactly as RelayConfiguration clamps them.
                        let effective = max(PublishPolicy.minimumPresenceTTL, ttl)
                        XCTAssertLessThanOrEqual(c.heartbeatInterval.value * 2, effective.value, "\(motion) \(battery) \(ttl)")
                        XCTAssertEqual(RelayConfiguration(presenceTTL: ttl).presenceTTL, effective)
                        XCTAssertGreaterThanOrEqual(c.heartbeatInterval, .seconds(1))
                        XCTAssertLessThanOrEqual(c.minInterval, c.heartbeatInterval)
                    }
                }
            }
        }
    }

    func testBatteryStretchesCadenceAndChargingRestoresIt() {
        let full = PublishPolicy.cadence(for: DeviceConditions(batteryLevel: 0.9, motion: .driving), presenceTTL: ttl)
        let half = PublishPolicy.cadence(for: DeviceConditions(batteryLevel: 0.3, motion: .driving), presenceTTL: ttl)
        let low = PublishPolicy.cadence(for: DeviceConditions(batteryLevel: 0.1, motion: .driving), presenceTTL: ttl)
        let lpm = PublishPolicy.cadence(for: DeviceConditions(batteryLevel: 0.9, isLowPowerMode: true, motion: .driving), presenceTTL: ttl)
        let charging = PublishPolicy.cadence(for: DeviceConditions(batteryLevel: 0.1, isCharging: true, motion: .driving), presenceTTL: ttl)
        XCTAssertEqual(full.minInterval, .seconds(5))
        XCTAssertEqual(half.minInterval, .seconds(10))
        XCTAssertEqual(low.minInterval, .seconds(20))
        XCTAssertEqual(lpm.minInterval, .seconds(20))
        XCTAssertEqual(charging.minInterval, .seconds(5))
        XCTAssertEqual(low.minDistanceMeters, 200)
    }

    func testNaNBatteryIsTreatedAsEmptyNotFull() {
        let c = DeviceConditions(batteryLevel: .nan, motion: .walking)
        XCTAssertEqual(c.batteryLevel, 0)
        XCTAssertEqual(PublishPolicy.cadence(for: c, presenceTTL: ttl).minInterval, .seconds(60))
    }

    // MARK: Gate

    func fix(_ lat: Double, at s: Int64, accuracy: Double = 5) -> LocationFix {
        // Force-unwrap is provably safe: every caller passes |lat| ≤ 1 and a finite, non-negative accuracy.
        LocationFix(latitude: lat, longitude: 0, accuracyMeters: accuracy, timestamp: Instant(millis: s * 1_000))!
    }

    let walking = PublishCadence(minInterval: .seconds(15), minDistanceMeters: 15, heartbeatInterval: .seconds(60))

    func testGateDecisionsInOrderOfPrecedence() {
        var gate = PublishGate()
        let start = fix(0, at: 0)
        XCTAssertEqual(gate.decide(start, now: Instant(millis: 0), cadence: walking), .publish(.first))
        gate.commit(start, at: Instant(millis: 0))

        let tenMetres = 10.0 / 111_195
        XCTAssertEqual(gate.decide(fix(0, at: 0), now: Instant(millis: 1_000), cadence: walking), .suppress(.outOfOrder))
        XCTAssertEqual(gate.decide(fix(0.001, at: 5), now: Instant(millis: 5_000), cadence: walking), .suppress(.tooSoon))
        XCTAssertEqual(gate.decide(fix(tenMetres, at: 20), now: Instant(millis: 20_000), cadence: walking), .suppress(.notMoved))
        XCTAssertEqual(gate.decide(fix(0.001, at: 20), now: Instant(millis: 20_000), cadence: walking), .publish(.moved))
        XCTAssertEqual(gate.decide(fix(0.001, at: 20, accuracy: 500), now: Instant(millis: 20_000), cadence: walking), .suppress(.inaccurate))
        XCTAssertEqual(gate.decide(fix(0.001, at: 20), now: Instant(millis: 20_000), cadence: walking, discretionaryAllowed: false),
                       .suppress(.budgetExhausted))
    }

    func testPoorAccuracyIsJudgedBeforeTimingAndMovement() {
        var gate = PublishGate()
        gate.commit(fix(0, at: 0), at: Instant(millis: 0))
        // Both "too soon" and "inaccurate" apply; the reason must be the accuracy one, so the counters tell
        // an operator the GPS is bad rather than that the cadence is working.
        XCTAssertEqual(gate.decide(fix(0.001, at: 5, accuracy: 500), now: Instant(millis: 5_000), cadence: walking), .suppress(.inaccurate))
    }

    func testAPoorFirstFixIsNeverPublished() {
        let gate = PublishGate()
        XCTAssertEqual(gate.decide(fix(0, at: 0, accuracy: 900), now: Instant(millis: 0), cadence: walking), .suppress(.inaccurate))
        XCTAssertEqual(gate.decide(fix(0, at: 0, accuracy: 5), now: Instant(millis: 0), cadence: walking), .publish(.first))
    }

    func testHeartbeatBeatsBothBudgetAndPoorAccuracy() {
        var gate = PublishGate()
        gate.commit(fix(0, at: 0), at: Instant(millis: 0))
        let late = fix(0, at: 61, accuracy: 900)
        XCTAssertEqual(gate.decide(late, now: Instant(millis: 61_000), cadence: walking, discretionaryAllowed: false),
                       .publish(.heartbeat))
        XCTAssertTrue(gate.heartbeatDue(now: Instant(millis: 60_000), cadence: walking))
        XCTAssertFalse(gate.heartbeatDue(now: Instant(millis: 59_999), cadence: walking))
        XCTAssertFalse(PublishGate().heartbeatDue(now: Instant(millis: 1_000_000), cadence: walking), "nothing to heartbeat yet")
    }

    func testGateSanitisesNonFiniteAccuracyThreshold() {
        XCTAssertEqual(PublishGate(maxAccuracyMeters: .nan).maxAccuracyMeters, 200)
        XCTAssertEqual(PublishGate(maxAccuracyMeters: -3).maxAccuracyMeters, 0)
    }

    // MARK: Token bucket

    func testBucketBurstThenExactRefill() {
        var b = TokenBucket(capacity: 3, refillEvery: .seconds(10), now: Instant(millis: 0))
        XCTAssertTrue(b.tryTake(now: Instant(millis: 0)))
        XCTAssertTrue(b.tryTake(now: Instant(millis: 0)))
        XCTAssertTrue(b.tryTake(now: Instant(millis: 0)))
        XCTAssertFalse(b.tryTake(now: Instant(millis: 9_999)))
        XCTAssertEqual(b.nextTokenAt(now: Instant(millis: 9_999)), Instant(millis: 10_000))
        XCTAssertTrue(b.tryTake(now: Instant(millis: 15_000)), "earned at 10 s, collected late at 15 s")
        // The 5 s remainder is kept: the next token is due at 20 s, not at 25 s.
        XCTAssertFalse(b.tryTake(now: Instant(millis: 19_999)))
        XCTAssertTrue(b.tryTake(now: Instant(millis: 20_000)))
    }

    func testBucketNeverExceedsCapacityAndSurvivesHostileInput() {
        var b = TokenBucket(capacity: 0, refillEvery: Millis(0), now: Instant(millis: 0))
        XCTAssertEqual(b.capacity, 1)
        XCTAssertEqual(b.refillEvery.value, 1)
        b.refill(now: Instant(millis: .max))
        XCTAssertEqual(b.tokens, 1)
        XCTAssertTrue(b.tryTake(now: Instant(millis: .max)))
        b.refill(now: Instant(millis: .min))          // clock jumps back to the dawn of time
        XCTAssertEqual(b.tokens, 0)
        XCTAssertTrue(b.tryTake(now: Instant(millis: Saturating.add(Int64.min, 1))), "re-anchored, then refilled after 1 ms")
    }
}
