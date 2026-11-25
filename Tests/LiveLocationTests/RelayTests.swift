import XCTest
@testable import LiveLocation

/// Builds opaque copies for relay tests; the relay never decrypts, so real crypto is not needed here.
func sealedCopy(_ share: String, _ viewer: String, _ seq: UInt64) -> SealedPoint {
    SealedPoint(shareID: ShareID(share), viewerID: ViewerID(viewer), sequence: seq,
                sharerPublicKey: Data(repeating: 1, count: 32), ciphertext: Data(repeating: UInt8(truncatingIfNeeded: seq), count: 64))
}

final class RelayTests: XCTestCase {
    let a = ViewerID("a"), b = ViewerID("b"), c = ViewerID("c")
    let s = ShareID("s")

    func makeRelay(_ config: RelayConfiguration = RelayConfiguration()) -> (LocationRelay, ManualClock) {
        let clock = ManualClock()
        return (LocationRelay(configuration: config, clock: clock), clock)
    }

    func testStartShareValidatesEveryLimit() async throws {
        let (relay, _) = makeRelay(RelayConfiguration(maxShareDuration: .hours(2), maxViewersPerShare: 2, maxActiveShares: 1))
        await XCTAssertThrowsAsync(try await relay.startShare(s, viewers: [a], duration: .zero), .invalidDuration)
        await XCTAssertThrowsAsync(try await relay.startShare(s, viewers: [a], duration: .hours(3)), .invalidDuration)
        await XCTAssertThrowsAsync(try await relay.startShare(s, viewers: [], duration: .hours(1)), .noViewers)
        await XCTAssertThrowsAsync(try await relay.startShare(s, viewers: [a, b, c], duration: .hours(1)), .tooManyViewers(limit: 2))
        try await relay.startShare(s, viewers: [a, b], duration: .hours(1))
        await XCTAssertThrowsAsync(try await relay.startShare(s, viewers: [a], duration: .hours(1)), .duplicateShare)
        await XCTAssertThrowsAsync(try await relay.startShare(ShareID("t"), viewers: [a], duration: .hours(1)), .capacityReached(limit: 1))
    }

    func testStoresOnlyTheLatestCopyPerViewer() async throws {
        let (relay, _) = makeRelay()
        try await relay.startShare(s, viewers: [a, b], duration: .hours(1))
        for seq in 1...500 as ClosedRange<UInt64> {
            _ = await relay.publish([sealedCopy("s", "a", seq), sealedCopy("s", "b", seq)])
        }
        let stats = await relay.stats
        XCTAssertEqual(stats.storedPoints, 2, "500 publishes, still one copy per (share, viewer)")
        let latestSeq = await relay.latest(s, for: a)?.sequence
        XCTAssertEqual(latestSeq, 500)
    }

    func testOutOfOrderDeliveryCannotMoveAPinBackwards() async throws {
        let (relay, _) = makeRelay()
        try await relay.startShare(s, viewers: [a], duration: .hours(1))
        _ = await relay.publish([sealedCopy("s", "a", 5)])
        let late = await relay.publish([sealedCopy("s", "a", 4)])
        XCTAssertEqual(late.rejected[a], .staleSequence)
        let replay = await relay.publish([sealedCopy("s", "a", 5)])
        XCTAssertEqual(replay.rejected[a], .staleSequence)
        let stored = await relay.latest(s, for: a)?.sequence
        XCTAssertEqual(stored, 5)
    }

    func testRejectsNonRecipientsAndUnknownShares() async throws {
        let (relay, _) = makeRelay()
        try await relay.startShare(s, viewers: [a], duration: .hours(1))
        let r = await relay.publish([sealedCopy("s", "mallory", 1), sealedCopy("nope", "a", 1)])
        XCTAssertEqual(r.rejected[ViewerID("mallory")], .notARecipient)
        XCTAssertEqual(r.rejected[a], .unknownShare)
        let stored = await relay.stats.storedPoints
        XCTAssertEqual(stored, 0)
    }

    func testShareExpiresByTimeAndEverythingIsDeleted() async throws {
        let (relay, clock) = makeRelay()
        try await relay.startShare(s, viewers: [a, b], duration: .minutes(10))
        let conn = try await relay.connect(a)
        _ = await relay.publish([sealedCopy("s", "a", 1), sealedCopy("s", "b", 1)])     // b is offline: queued for push
        clock.advance(by: .minutes(10))
        let afterExpiry = await relay.publish([sealedCopy("s", "a", 2)])
        XCTAssertEqual(afterExpiry.rejected[a], .unknownShare, "swept on the way in")
        let stats = await relay.stats
        XCTAssertEqual(stats.activeShares, 0)
        XCTAssertEqual(stats.storedPoints, 0)
        XCTAssertEqual(stats.pendingPushes, 0)
        let presence = await relay.presence(of: s)
        XCTAssertEqual(presence, .unknownShare)
        let points = await first(conn.points, count: 1)
        XCTAssertEqual(points, [sealedCopy("s", "a", 1)])
        let control = await first(conn.control, count: 1)
        XCTAssertEqual(control, [.ended(s, .expired)])
    }

    func testAnExpiredButUnsweptIDCanBeRestarted() async throws {
        let (relay, clock) = makeRelay()
        try await relay.startShare(s, viewers: [a], duration: .minutes(1))
        clock.advance(by: .minutes(2))                       // expired; nothing has swept yet
        try await relay.startShare(s, viewers: [a], duration: .minutes(1))
        let expiry = await relay.expiry(of: s)
        XCTAssertEqual(expiry, clock.now().adding(.minutes(1)))
    }

    func testAddViewerMidShareRespectsTheLimit() async throws {
        let (relay, _) = makeRelay(RelayConfiguration(maxViewersPerShare: 2))
        try await relay.startShare(s, viewers: [a], duration: .hours(1))
        let before = await relay.publish([sealedCopy("s", "b", 1)])
        XCTAssertEqual(before.rejected[b], .notARecipient)
        try await relay.addViewer(b, to: s)
        let after = await relay.publish([sealedCopy("s", "b", 2)])
        XCTAssertEqual(after.queuedForPush, [b])
        await XCTAssertThrowsAsync(try await relay.addViewer(c, to: s), .tooManyViewers(limit: 2))
        await XCTAssertThrowsAsync(try await relay.addViewer(c, to: ShareID("nope")), .unknownShare)
        let sharesForB = await relay.shares(for: b)
        XCTAssertEqual(sharesForB, [s])
    }

    func testPushQueueIsServedOldestFirstSoABusyShareCannotStarveAQuietOne() async throws {
        let (relay, clock) = makeRelay(RelayConfiguration(pushBurst: 1, pushRefill: .minutes(5)))
        let busy = ShareID("a-busy"), quiet = ShareID("b-quiet")
        try await relay.startShare(busy, viewers: [a], duration: .hours(2))
        try await relay.startShare(quiet, viewers: [a], duration: .hours(2))
        _ = await relay.publish([sealedCopy("a-busy", "a", 1)])
        _ = await relay.drainPushes()                          // spends the only token
        clock.advance(by: .seconds(10))
        _ = await relay.publish([sealedCopy("b-quiet", "a", 1)])  // quiet share starts waiting at t=10 s
        var delivered: [String] = []
        for minute in 1...10 {
            clock.advance(by: .minutes(1))
            _ = await relay.publish([sealedCopy("a-busy", "a", UInt64(minute + 1))])   // busy keeps publishing
            delivered += await relay.drainPushes().map(\.sealed.shareID.raw)
        }
        XCTAssertEqual(delivered.first, "b-quiet", "the quiet share waited longest, so it goes first")
        XCTAssertTrue(delivered.contains("a-busy"))
    }

    func testRevocationDeletesStoredCopyAndQueuedPushAndNotifies() async throws {
        let (relay, _) = makeRelay()
        try await relay.startShare(s, viewers: [a, b], duration: .hours(1))
        let conn = try await relay.connect(a)
        _ = await relay.publish([sealedCopy("s", "a", 1), sealedCopy("s", "b", 1)])
        await relay.revoke(b, from: s)
        await relay.revoke(a, from: s)
        let stats = await relay.stats
        XCTAssertEqual(stats.storedPoints, 0)
        XCTAssertEqual(stats.pendingPushes, 0)
        let late = await relay.publish([sealedCopy("s", "b", 2)])
        XCTAssertEqual(late.rejected[b], .notARecipient, "a copy sealed before revocation is refused when it arrives after")
        let control = await first(conn.control, count: 1)
        XCTAssertEqual(control, [.revoked(s)])
        let pushes = await relay.drainPushes()
        XCTAssertEqual(pushes, [])
        let budgets = await relay.stats.pushBudgets
        XCTAssertEqual(budgets, 0, "viewers on no share keep no budget entry")
    }

    func testPresenceGoesAwayAfterTTL() async throws {
        let (relay, clock) = makeRelay(RelayConfiguration(presenceTTL: .seconds(120)))
        try await relay.startShare(s, viewers: [a], duration: .hours(1))
        let waiting = await relay.presence(of: s)
        XCTAssertEqual(waiting, .awaitingFirstPoint)
        _ = await relay.publish([sealedCopy("s", "a", 1)])
        let seen = clock.now()
        clock.advance(by: .seconds(120))
        let atTTL = await relay.presence(of: s)
        XCTAssertEqual(atTTL, .online(lastSeen: seen))
        clock.advance(by: Millis(1))
        let pastTTL = await relay.presence(of: s)
        XCTAssertEqual(pastTTL, .away(lastSeen: seen))
    }

    func testPushBudgetBurstsThenRefillsAndCoalescesToNewest() async throws {
        let (relay, clock) = makeRelay(RelayConfiguration(pushBurst: 2, pushRefill: .minutes(5)))
        try await relay.startShare(s, viewers: [a], duration: .hours(2))
        var sent: [UInt64] = []
        var coalesced = 0
        for seq in 1...30 as ClosedRange<UInt64> {            // one point every 30 s for 15 min
            _ = await relay.publish([sealedCopy("s", "a", seq)])
            for p in await relay.drainPushes() { sent.append(p.sealed.sequence); coalesced += p.coalesced }
            clock.advance(by: .seconds(30))
        }
        // Burst of 2 (t=0, t=30 s), then one token per 5 min after the bucket's anchor at t=0:
        // t=5 m carries #11 (it replaced #3…#10: 8 older points), t=10 m carries #21 (replaced #12…#20: 9).
        XCTAssertEqual(sent, [1, 2, 11, 21])
        XCTAssertEqual(coalesced, 8 + 9, "each budget-delayed push carries the newest point, not a backlog")
        let pending = await relay.stats.pendingPushes
        XCTAssertEqual(pending, 1, "the newest point is waiting, coalesced, not a backlog")
    }

    func testConnectReplaysLatestAndTakesOverQueuedPushes() async throws {
        let (relay, _) = makeRelay()
        try await relay.startShare(s, viewers: [a], duration: .hours(1))
        _ = await relay.publish([sealedCopy("s", "a", 1)])
        _ = await relay.publish([sealedCopy("s", "a", 2)])
        let conn = try await relay.connect(a)
        let pendingAfterConnect = await relay.stats.pendingPushes
        XCTAssertEqual(pendingAfterConnect, 0)
        let events = await first(conn.points, count: 1)
        XCTAssertEqual(events, [sealedCopy("s", "a", 2)], "catch-up is the latest copy only")
        let r = await relay.publish([sealedCopy("s", "a", 3)])
        XCTAssertEqual(r.deliveredLive, [a])
    }

    func testSlowConsumerKeepsOnlyNewestPointsButNeverLosesControlEvents() async throws {
        let (relay, _) = makeRelay(RelayConfiguration(connectionBuffer: 3))
        let other = ShareID("t")
        try await relay.startShare(s, viewers: [a], duration: .hours(1))
        try await relay.startShare(other, viewers: [a], duration: .hours(1))
        let conn = try await relay.connect(a)
        await relay.stopShare(s)                             // "remove the pin" for share s, sent FIRST…
        for seq in 1...50 as ClosedRange<UInt64> { _ = await relay.publish([sealedCopy("t", "a", seq)]) }  // …then a burst
        let events = await first(conn.points, count: 3)
        XCTAssertEqual(events, [sealedCopy("t", "a", 48), sealedCopy("t", "a", 49), sealedCopy("t", "a", 50)])
        let control = await first(conn.control, count: 1)
        XCTAssertEqual(control, [.ended(s, .stopped)], "a later burst of points can never evict an earlier control event")
    }

    func testAJunkCopyAtUInt64MaxIsRejected() async throws {
        let (relay, clock) = makeRelay()
        try await relay.startShare(s, viewers: [a], duration: .hours(1))
        let junk = await relay.publish([sealedCopy("s", "a", .max)])
        XCTAssertEqual(junk.rejected[a], .futureSequence)
        let genuine = await relay.publish([sealedCopy("s", "a", SharerSession.epochSequence(clock.now()))])
        XCTAssertEqual(genuine.queuedForPush, [a], "the real sharer is not locked out")
        let skewed = SharerSession.epochSequence(clock.now().adding(.minutes(4)))
        let ahead = await relay.publish([sealedCopy("s", "a", skewed)])
        XCTAssertEqual(ahead.queuedForPush, [a], "a sharer clock up to 5 min ahead is accepted")
    }

    func testConnectRefusesStrangersAndCapsConnectionsPerViewer() async throws {
        let (relay, _) = makeRelay(RelayConfiguration(maxConnectionsPerViewer: 2))
        await XCTAssertThrowsAsync(try await relay.connect(a), .notAViewer)
        try await relay.startShare(s, viewers: [a], duration: .hours(1))
        let c1 = try await relay.connect(a)
        let c2 = try await relay.connect(a)
        await XCTAssertThrowsAsync(try await relay.connect(a), .tooManyConnections(limit: 2))
        _ = (c1, c2)
    }

    func testAViewerLeftOnNoShareIsDisconnected() async throws {
        let (relay, _) = makeRelay()
        try await relay.startShare(s, viewers: [a], duration: .hours(1))
        let conn = try await relay.connect(a)
        await relay.revoke(a, from: s)
        let live = await relay.stats.liveConnections
        XCTAssertEqual(live, 0)
        let control = await first(conn.control, count: 1)
        XCTAssertEqual(control, [.revoked(s)], "the revoke is delivered first")
        // …and then both streams actually finish (not just drop out of the stats).
        let finished = Task { () -> Bool in
            for await _ in conn.points {}
            return !Task.isCancelled
        }
        let timer = Task { try? await Task.sleep(for: .seconds(1)); finished.cancel() }
        let ended = await finished.value
        timer.cancel()
        XCTAssertTrue(ended, "the relay closed the stream")
    }

    func testRevokeAndReAddCannotResetAPushBudget() async throws {
        let (relay, clock) = makeRelay(RelayConfiguration(pushBurst: 1, pushRefill: .minutes(5)))
        try await relay.startShare(s, viewers: [a], duration: .hours(1))
        _ = await relay.publish([sealedCopy("s", "a", 1)])
        let first = await relay.drainPushes()
        XCTAssertEqual(first.count, 1)                       // burst spent
        await relay.revoke(a, from: s)
        _ = await relay.drainPushes()                        // housekeeping runs while she is on no share
        try await relay.addViewer(a, to: s)
        clock.advance(by: .seconds(10))
        _ = await relay.publish([sealedCopy("s", "a", 2)])
        let second = await relay.drainPushes()
        XCTAssertEqual(second.count, 0, "the bucket survived the revoke/re-add")
        clock.advance(by: .minutes(5))
        let third = await relay.drainPushes()
        XCTAssertEqual(third.count, 1)
    }

    func testDisconnectedStreamFallsBackToPush() async throws {
        let (relay, _) = makeRelay()
        try await relay.startShare(s, viewers: [a], duration: .hours(1))
        var conn: RelayConnection? = try await relay.connect(a)
        XCTAssertNotNil(conn)
        conn = nil                                            // dropping the last reference terminates it
        for _ in 0..<200 {
            if await relay.stats.liveConnections == 0 { break }
            await Task.yield()
        }
        let live = await relay.stats.liveConnections
        XCTAssertEqual(live, 0)
        let r = await relay.publish([sealedCopy("s", "a", 1)])
        XCTAssertEqual(r.queuedForPush, [a])
    }

    func testStopShareIsExplicitAndIdempotent() async throws {
        let (relay, _) = makeRelay()
        try await relay.startShare(s, viewers: [a], duration: .hours(1))
        await relay.stopShare(s)
        await relay.stopShare(s)
        let viewers = await relay.viewers(of: s)
        XCTAssertEqual(viewers, [])
        try await relay.startShare(s, viewers: [a], duration: .hours(1))   // the id is reusable after stop
    }

    // MARK: helpers

    /// Reads up to `count` events, giving up after `timeout` so a regression fails the test instead of hanging it.
    func first<T: Sendable>(_ stream: AsyncStream<T>, count: Int, timeout: Duration = .seconds(2)) async -> [T] {
        let reader = Task {
            var out: [T] = []
            for await e in stream {
                out.append(e)
                if out.count == count { break }
            }
            return out
        }
        let timer = Task {
            try? await Task.sleep(for: timeout)
            reader.cancel()
        }
        let events = await reader.value
        timer.cancel()
        return events
    }
}

func XCTAssertThrowsAsync<T>(_ expr: @autoclosure () async throws -> T, _ expected: RelayError,
                             file: StaticString = #filePath, line: UInt = #line) async {
    do {
        _ = try await expr()
        XCTFail("expected \(expected)", file: file, line: line)
    } catch {
        XCTAssertEqual(error as? RelayError, expected, file: file, line: line)
    }
}
