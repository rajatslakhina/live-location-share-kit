import XCTest
@testable import LiveLocation

/// An uplink whose next upload parks until the test releases it — the tool for proving what happens
/// when another call runs inside `SharerSession` at its `await`.
actor GatedUplink: RelayUplink {
    let relay: LocationRelay
    nonisolated var presenceTTL: Millis { relay.configuration.presenceTTL }
    private var holdNext = false
    private var holdNextRevokeCall = false
    private var holdAfterNextRevokeCall = false
    private var holdAfterNextAddCall = false
    private(set) var revokeCalls = 0
    var parkedCount: Int { parked.count }
    private var parked: [CheckedContinuation<Void, Never>] = []
    private(set) var uploads: [[SealedPoint]] = []
    var failing = false
    /// Answer `revoke` and `stop` with `RelayError.unknownShare`, as an HTTPS relay would for an expired share.
    var unknownShareOnCleanup = false

    init(relay: LocationRelay) { self.relay = relay }
    func holdNextUpload() { holdNext = true }
    func holdNextRevoke() { holdNextRevokeCall = true }
    /// Park the next revoke *after* the relay applied it: a slow reply.
    func holdAfterNextRevoke() { holdAfterNextRevokeCall = true }
    /// Park the next add *after* the relay applied it: a slow reply.
    func holdAfterNextAdd() { holdAfterNextAddCall = true }
    func setFailing(_ f: Bool) { failing = f }
    func setUnknownShareOnCleanup(_ u: Bool) { unknownShareOnCleanup = u }
    func release() { parked.forEach { $0.resume() }; parked = [] }

    func upload(_ copies: [SealedPoint]) async throws -> PublishReceipt {
        uploads.append(copies)
        if holdNext {
            holdNext = false
            await withCheckedContinuation { parked.append($0) }
        }
        if failing { throw URLError(.notConnectedToInternet) }
        return await relay.publish(copies)
    }

    func revoke(_ viewer: ViewerID, from share: ShareID) async throws {
        revokeCalls += 1
        if holdNextRevokeCall {
            holdNextRevokeCall = false
            await withCheckedContinuation { parked.append($0) }
        }
        if failing { throw URLError(.notConnectedToInternet) }
        if unknownShareOnCleanup { throw RelayError.unknownShare }
        await relay.revoke(viewer, from: share)
        if holdAfterNextRevokeCall {
            holdAfterNextRevokeCall = false
            await withCheckedContinuation { parked.append($0) }
        }
    }

    func stop(_ share: ShareID) async throws {
        if failing { throw URLError(.notConnectedToInternet) }
        if unknownShareOnCleanup { throw RelayError.unknownShare }
        await relay.stopShare(share)
    }

    func addViewer(_ viewer: ViewerID, to share: ShareID) async throws {
        if failing { throw URLError(.notConnectedToInternet) }
        do {
            try await relay.addViewer(viewer, to: share)
        } catch {
            if holdAfterNextAddCall {                                   // a slow refusal
                holdAfterNextAddCall = false
                await withCheckedContinuation { parked.append($0) }
            }
            throw error
        }
        if holdAfterNextAddCall {
            holdAfterNextAddCall = false
            await withCheckedContinuation { parked.append($0) }
        }
    }
}

final class SharerSessionTests: XCTestCase {
    let share = ShareID("s")
    let manifest = CapabilityManifest(capabilities: [.liveLocationSharing])
    let walking = DeviceConditions(batteryLevel: 0.9, motion: .walking)
    let keys = ["a", "b", "c"].map { ViewerKeys(viewerID: ViewerID($0)) }
    var sealer = PerViewerSealer(shareID: ShareID("s"))

    func setUp(budget: Int = 120, startingSequence: UInt64? = 1) async throws -> (SharerSession, GatedUplink, LocationRelay, ManualClock) {
        let clock = ManualClock(start: Instant(millis: 1_000_000))
        let relay = LocationRelay(configuration: RelayConfiguration(presenceTTL: .seconds(120)), clock: clock)
        try await relay.startShare(share, viewers: Set(keys.map(\.viewerID)), duration: .hours(1))
        var sealer = PerViewerSealer(shareID: share)
        for k in keys { try sealer.add(k.viewerID, publicKey: k.publicKey) }
        let uplink = GatedUplink(relay: relay)
        let session = try SharerSession(shareID: share, manifest: manifest, sealer: sealer, uplink: uplink, clock: clock, discretionaryBudget: budget,
                                        budgetRefill: .hours(1), startingSequence: startingSequence)
        self.sealer = sealer
        return (session, uplink, relay, clock)
    }

    func fix(_ lat: Double, _ clock: ManualClock) -> LocationFix {
        // Force-unwrap is provably safe: callers pass |lat| < 1 and a fixed valid accuracy.
        LocationFix(latitude: lat, longitude: 0, accuracyMeters: 5, timestamp: clock.now())!
    }

    func testSessionRefusesToExistWithoutTheDeclaredCapability() {
        XCTAssertThrowsError(try SharerSession(shareID: share, manifest: CapabilityManifest(capabilities: [.locationForAppFeatures]),
                                               sealer: PerViewerSealer(shareID: share), uplink: LocationRelay(),
                                               clock: ManualClock())) {
            XCTAssertEqual($0 as? SessionError, .capabilityNotDeclared)
        }
    }

    func testOverlappingIngestsGetIncreasingSequencesAndTheLateOneLoses() async throws {
        let (session, uplink, relay, clock) = try await setUp()
        _ = await session.ingest(fix(0, clock), conditions: walking)                // #1, first
        clock.advance(by: .seconds(20))
        await uplink.holdNextUpload()
        let slowFix = fix(0.001, clock), conditions = walking
        let slow = Task { await session.ingest(slowFix, conditions: conditions) }       // #2, parked
        while await uplink.uploads.count < 2 { await Task.yield() }
        clock.advance(by: .seconds(61))                                                  // heartbeat due
        let fast = await session.ingest(fix(0.002, clock), conditions: walking)         // #3 — runs at #2's await
        guard case .published(.heartbeat, let fastSeq, _) = fast else { return XCTFail("\(fast)") }
        await uplink.release()
        let slowOutcome = await slow.value
        guard case .rejected(let slowSeq, let receipt) = slowOutcome else { return XCTFail("\(slowOutcome)") }
        XCTAssertLessThan(slowSeq, fastSeq, "sequence numbers are assigned before the await, in call order")
        XCTAssertEqual(Set(receipt.rejected.values), [.staleSequence], "the late upload is dropped by the relay")
        let stored = await relay.latest(share, for: ViewerID("a"))?.sequence
        XCTAssertEqual(stored, fastSeq)
        let counters = await session.counters
        XCTAssertEqual(counters.uploaded, 2, "the rejected late batch is sealed but not counted as uploaded")
        XCTAssertEqual(counters.sealed, 3)
    }

    func testRevokeDuringAnInFlightUploadStillExcludesTheViewer() async throws {
        let (session, uplink, relay, clock) = try await setUp()
        let carol = ViewerID("c")
        _ = await session.ingest(fix(0, clock), conditions: walking)
        clock.advance(by: .seconds(20))
        await uplink.holdNextUpload()
        let inFlightFix = fix(0.001, clock), conditions = walking
        let inFlight = Task { await session.ingest(inFlightFix, conditions: conditions) }  // sealed for c, parked
        while await uplink.uploads.count < 2 { await Task.yield() }
        await session.revoke(carol)                                                    // runs at the await
        clock.advance(by: .seconds(61))
        _ = await session.tick(conditions: walking)
        await uplink.release()
        _ = await inFlight.value
        let uploads = await uplink.uploads
        XCTAssertEqual(uploads.count, 3)
        guard uploads.count == 3 else { return }
        XCTAssertTrue(uploads[1].contains { $0.viewerID == carol }, "the parked batch was sealed before the revoke")
        XCTAssertFalse(uploads[2].contains { $0.viewerID == carol }, "nothing sealed after revoke is addressed to Carol")
        let carolCopy = await relay.latest(share, for: carol)
        XCTAssertNil(carolCopy, "and the late pre-revoke copy is refused by the relay")
    }

    func testRevokeDuringAFailingUploadNeverLeaksToTheRevokedViewer() async throws {
        let (session, uplink, relay, clock) = try await setUp()
        let carol = ViewerID("c")
        _ = await session.ingest(fix(0, clock), conditions: walking)
        clock.advance(by: .seconds(20))
        await uplink.holdNextUpload()
        let inFlightFix = fix(0.001, clock), conditions = walking
        let inFlight = Task { await session.ingest(inFlightFix, conditions: conditions) }   // sealed for c, parked
        while await uplink.uploads.count < 2 { await Task.yield() }
        await uplink.setFailing(true)                                                   // network dies
        let acknowledged = await session.revoke(carol)
        XCTAssertFalse(acknowledged, "the relay never heard about it")
        await uplink.release()
        let outcome = await inFlight.value
        XCTAssertEqual(outcome, .heldOffline(sequence: 2))
        let held = await session.heldBatchRecipients
        XCTAssertEqual(held, [ViewerID("a"), ViewerID("b")], "the batch sealed before the revoke went back to the outbox without Carol")
        await uplink.setFailing(false)
        let pendingBefore = await session.unacknowledgedRevocations
        XCTAssertEqual(pendingBefore, [carol])
        _ = await session.flushOutbox()
        let uploads = await uplink.uploads
        XCTAssertFalse(uploads.last?.contains { $0.viewerID == carol } ?? true, "and nothing addressed to Carol was uploaded")
        let pendingAfter = await session.unacknowledgedRevocations
        XCTAssertEqual(pendingAfter, [], "the relay revocation was retried and acknowledged")
        let carolOnShare = await relay.viewers(of: share).contains(carol)
        XCTAssertFalse(carolOnShare)
    }

    func testARelaunchedSessionOnTheSameShareIsAccepted() async throws {
        // Default sequences are epoch-based, so a fresh session (new process, same share key) starts above
        // everything the old one sent.
        let (old, _, relay, clock) = try await setUp(startingSequence: nil)
        for i in 1...5 {
            _ = await old.ingest(fix(Double(i) * 0.001, clock), conditions: walking)
            clock.advance(by: .seconds(20))
        }
        let restored = try PerViewerSealer(shareID: share, privateKeyRaw: sealer.privateKeyRaw)
        var restoredWithViewers = restored
        for k in keys { try restoredWithViewers.add(k.viewerID, publicKey: k.publicKey) }
        let relaunched = try SharerSession(shareID: share, manifest: manifest, sealer: restoredWithViewers,
                                           uplink: relay, clock: clock)
        let outcome = await relaunched.ingest(fix(0.5, clock), conditions: walking)
        guard case .published(.first, _, let receipt) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(receipt.rejected, [:], "not mistaken for a replay")
        var opener = PerViewerOpener(keys: keys[0])
        opener.trust(share, sharerPublicKey: sealer.sharePublicKey)    // the pin from the original invitation
        let latest = await relay.latest(share, for: keys[0].viewerID)
        XCTAssertEqual(try opener.open(try XCTUnwrap(latest)).fix.latitude, 0.5)
        // Control: a relaunch that restarted sequences at 1 would be locked out.
        let naive = try SharerSession(shareID: share, manifest: manifest, sealer: restoredWithViewers, uplink: relay,
                                      clock: clock, startingSequence: 1)
        clock.advance(by: .seconds(20))
        let locked = await naive.ingest(fix(0.6, clock), conditions: walking)
        guard case .rejected(_, let lockedReceipt) = locked else { return XCTFail("\(locked)") }
        XCTAssertEqual(Set(lockedReceipt.rejected.values), [.staleSequence])
    }

    func testEpochSequenceIsMonotonicInTimeAndNeverTraps() {
        XCTAssertLessThan(SharerSession.epochSequence(Instant(millis: 1_000)), SharerSession.epochSequence(Instant(millis: 1_001)))
        XCTAssertEqual(SharerSession.epochSequence(Instant(millis: -5)), 0)
        XCTAssertEqual(SharerSession.epochSequence(Instant(millis: .max)), UInt64.max, "saturates, never wraps backwards")
        XCTAssertEqual(SharerSession.epochSequence(Instant(millis: 1 << 47)), 1 << 63)
        XCTAssertLessThan(SharerSession.epochSequence(Instant(millis: (1 << 48) - 1)), .max)
        XCTAssertEqual(SharerSession.epochSequence(Instant(millis: 1 << 48)), .max, "the first value that would overflow saturates")
    }

    func testSessionStopsWhenTheRelayHasForgottenTheShare() async throws {
        let (session, uplink, relay, clock) = try await setUp()
        _ = await session.ingest(fix(0, clock), conditions: walking)
        await relay.stopShare(share)                                  // e.g. expired server-side
        clock.advance(by: .seconds(61))
        let outcome = await session.tick(conditions: walking)
        XCTAssertEqual(outcome, .ended)
        let uploadsAtEnd = await uplink.uploads.count
        clock.advance(by: .seconds(61))
        let after = await session.tick(conditions: walking)
        XCTAssertEqual(after, .ended)
        let uploadsLater = await uplink.uploads.count
        XCTAssertEqual(uploadsLater, uploadsAtEnd, "nothing more is sealed or uploaded")
    }

    func testStopEndsLocallyAndAtTheRelay() async throws {
        let (session, _, relay, clock) = try await setUp()
        _ = await session.ingest(fix(0, clock), conditions: walking)
        await session.stop()
        let ended = await session.isEnded
        XCTAssertTrue(ended)
        let presence = await relay.presence(of: share)
        XCTAssertEqual(presence, .unknownShare)
        let again = await session.ingest(fix(0.1, clock), conditions: walking)
        XCTAssertEqual(again, .ended)
    }

    func testAHeartbeatOnAPoorFixResendsTheLastGoodFix() async throws {
        let (session, _, relay, clock) = try await setUp()
        _ = await session.ingest(fix(0.25, clock), conditions: walking)
        clock.advance(by: .seconds(61))
        let poor = try XCTUnwrap(LocationFix(latitude: 0.9, longitude: 0, accuracyMeters: 900, timestamp: clock.now()))
        let outcome = await session.ingest(poor, conditions: walking)
        guard case .published(.heartbeat, _, _) = outcome else { return XCTFail("\(outcome)") }
        var opener = PerViewerOpener(keys: keys[0])
        opener.trust(share, sharerPublicKey: sealer.sharePublicKey)
        let latest = await relay.latest(share, for: keys[0].viewerID)
        XCTAssertEqual(try opener.open(try XCTUnwrap(latest)).fix.latitude, 0.25, "the 900 m estimate never reaches a viewer")
    }

    func testCountersSeparateSealedFromUploaded() async throws {
        let (session, uplink, _, clock) = try await setUp()
        await uplink.setFailing(true)
        _ = await session.ingest(fix(0, clock), conditions: walking)
        var c = await session.counters
        XCTAssertEqual(c.sealed, 1)
        XCTAssertEqual(c.uploaded, 0)
        XCTAssertEqual(c.heldOffline, 1)
        await uplink.setFailing(false)
        _ = await session.flushOutbox()
        c = await session.counters
        XCTAssertEqual(c.uploaded, 1, "counted once, when the relay actually received it")
    }

    func testAViewerAddedMidShareGetsTheNextPoint() async throws {
        let (session, _, relay, clock) = try await setUp()
        _ = await session.ingest(fix(0, clock), conditions: walking)
        let dana = ViewerKeys(viewerID: ViewerID("d"))
        try await session.addViewer(dana.viewerID, publicKey: dana.publicKey)   // device + relay in one call
        clock.advance(by: .seconds(20))
        _ = await session.ingest(fix(0.3, clock), conditions: walking)
        var opener = PerViewerOpener(keys: dana)
        opener.trust(share, sharerPublicKey: sealer.sharePublicKey)
        let latest = await relay.latest(share, for: dana.viewerID)
        XCTAssertEqual(try opener.open(try XCTUnwrap(latest)).fix.latitude, 0.3)
    }

    func testAStopThatFailsOfflineIsRetriedWithPendingRevocations() async throws {
        let (session, uplink, relay, clock) = try await setUp()
        _ = await session.ingest(fix(0, clock), conditions: walking)
        await uplink.setFailing(true)
        let revoked = await session.revoke(ViewerID("c"))
        let stopped = await session.stop()
        XCTAssertFalse(revoked)
        XCTAssertFalse(stopped)
        let stillThere = await relay.presence(of: share)
        XCTAssertNotEqual(stillThere, .unknownShare, "the relay never heard the stop")
        await uplink.setFailing(false)
        let outcome = await session.flushOutbox()
        XCTAssertEqual(outcome, .ended)
        let gone = await relay.presence(of: share)
        XCTAssertEqual(gone, .unknownShare, "the stop was retried after the share ended locally")
        let pendingStop = await session.stopUnacknowledged
        let pendingRevokes = await session.unacknowledgedRevocations
        XCTAssertFalse(pendingStop)
        XCTAssertEqual(pendingRevokes, [])
    }

    func testARevokeThatFailedCannotRevokeAViewerWhoWasReAdded() async throws {
        let (session, uplink, relay, clock) = try await setUp()
        let carol = ViewerID("c")
        _ = await session.ingest(fix(0, clock), conditions: walking)
        await uplink.setFailing(true)
        let acknowledged = await session.revoke(carol)                  // fails: queued for retry
        XCTAssertFalse(acknowledged)
        await uplink.setFailing(false)
        try await session.addViewer(carol, publicKey: keys[2].publicKey)  // re-added before the retry
        let pending = await session.unacknowledgedRevocations
        XCTAssertEqual(pending, [], "re-adding cancels the queued revoke")
        let revokesBefore = await uplink.revokeCalls
        _ = await session.flushOutbox()                                // must NOT revoke her again
        let revokesAfter = await uplink.revokeCalls
        XCTAssertEqual(revokesAfter, revokesBefore, "no relay revoke was sent for a re-added viewer")
        clock.advance(by: .seconds(61))
        _ = await session.tick(conditions: walking)
        let onShare = await relay.viewers(of: share).contains(carol)
        XCTAssertTrue(onShare, "the stale revoke was dropped")
        let latest = await relay.latest(share, for: carol)
        XCTAssertNotNil(latest, "and she receives the next point")
    }

    func testAViewerReAddedWhileTheirRevokeIsInFlightIsNotQueuedForRevocation() async throws {
        let (session, uplink, _, clock) = try await setUp()
        let carol = ViewerID("c")
        _ = await session.ingest(fix(0, clock), conditions: walking)
        await uplink.holdNextRevoke()
        let revoking = Task { await session.revoke(carol) }               // parks inside the relay call
        while await uplink.revokeCalls < 1 { await Task.yield() }
        try await session.addViewer(carol, publicKey: keys[2].publicKey)   // runs at revoke's await
        await uplink.setFailing(true)
        await uplink.release()
        let acknowledged = await revoking.value                          // the relay call fails…
        XCTAssertFalse(acknowledged)
        let pending = await session.unacknowledgedRevocations
        XCTAssertEqual(pending, [], "…but she was re-added meanwhile, so nothing is queued to revoke her")
        await uplink.setFailing(false)
        _ = await session.flushOutbox()
        let addsAfter = await session.unacknowledgedAdds
        XCTAssertEqual(addsAfter, [], "the re-sent add was acknowledged")
    }

    func testAReAddDuringASuccessfulRevokeEndsWithTheViewerOnTheRelay() async throws {
        let (session, uplink, relay, clock) = try await setUp()
        let carol = ViewerID("c")
        _ = await session.ingest(fix(0, clock), conditions: walking)
        await uplink.holdNextRevoke()
        let revoking = Task { await session.revoke(carol) }               // parked before reaching the relay
        while await uplink.revokeCalls < 1 { await Task.yield() }
        try await session.addViewer(carol, publicKey: keys[2].publicKey)   // parks: the in-flight revoke's reconciler sends the add afterwards
        await uplink.release()                                           // …then the revoke lands and removes her
        _ = await revoking.value
        let onShare = await relay.viewers(of: share).contains(carol)
        XCTAssertTrue(onShare, "the session re-sent the add after the late revoke")
        clock.advance(by: .seconds(61))
        _ = await session.tick(conditions: walking)
        let latest = await relay.latest(share, for: carol)
        XCTAssertNotNil(latest)
    }

    func testAnOfflineReAddIsQueuedAndTheStaleRevokeIsDropped() async throws {
        let (session, uplink, relay, clock) = try await setUp()
        let carol = ViewerID("c")
        _ = await session.ingest(fix(0, clock), conditions: walking)
        await uplink.setFailing(true)
        _ = await session.revoke(carol)
        let added = try await session.addViewer(carol, publicKey: keys[2].publicKey)
        XCTAssertFalse(added, "not acknowledged offline")
        let adds = await session.unacknowledgedAdds
        let revokes = await session.unacknowledgedRevocations
        XCTAssertEqual(adds, [carol])
        XCTAssertEqual(revokes, [], "the intent is now 'share with Carol'")
        await uplink.setFailing(false)
        _ = await session.flushOutbox()
        let addsAfter = await session.unacknowledgedAdds
        XCTAssertEqual(addsAfter, [])
        let onShare = await relay.viewers(of: share).contains(carol)
        XCTAssertTrue(onShare)
    }

    func testAnOfflineAddOfANewViewerIsRetriedByFlush() async throws {
        let (session, uplink, relay, clock) = try await setUp()
        _ = await session.ingest(fix(0, clock), conditions: walking)
        let dana = ViewerKeys(viewerID: ViewerID("d"))
        await uplink.setFailing(true)
        let added = try await session.addViewer(dana.viewerID, publicKey: dana.publicKey)
        XCTAssertFalse(added)
        await uplink.setFailing(false)
        _ = await session.flushOutbox()
        let onShare = await relay.viewers(of: share).contains(dana.viewerID)
        XCTAssertTrue(onShare, "the queued add reached the relay")
    }

    func testAddViewerAfterStopThrows() async throws {
        let (session, _, _, _) = try await setUp()
        await session.stop()
        do {
            try await session.addViewer(ViewerID("z"), publicKey: ViewerKeys(viewerID: ViewerID("z")).publicKey)
            XCTFail("expected shareEnded")
        } catch {
            XCTAssertEqual(error as? SessionError, .shareEnded)
        }
    }

    func testClockDrivenSequencesOutrunAJunkCopyOnceTheClockPassesIt() async throws {
        let (session, _, relay, clock) = try await setUp(startingSequence: nil)
        _ = await session.ingest(fix(0, clock), conditions: walking)
        let junk = SharerSession.epochSequence(clock.now().adding(.minutes(5)))
        _ = await relay.publish([SealedPoint(shareID: share, viewerID: ViewerID("a"), sequence: junk,
                                             sharerPublicKey: Data(repeating: 1, count: 32), ciphertext: Data([1]))])
        clock.advance(by: .seconds(61))
        let blocked = await session.tick(conditions: walking)
        guard case .published(_, _, let r1) = blocked else { return XCTFail("\(blocked)") }
        XCTAssertEqual(r1.rejected[ViewerID("a")], .staleSequence, "inside the window the junk still wins")
        clock.advance(by: .minutes(5))
        let unblocked = await session.tick(conditions: walking)
        guard case .published(_, _, let r2) = unblocked else { return XCTFail("\(unblocked)") }
        XCTAssertEqual(r2.rejected, [:], "once the clock passes the junk, genuine copies win again")
    }

    func testASlowReplyToAnOlderRevokeCannotClearANewerPendingRevoke() async throws {
        let (session, uplink, relay, clock) = try await setUp()
        let carol = ViewerID("c")
        _ = await session.ingest(fix(0, clock), conditions: walking)
        await uplink.holdAfterNextRevoke()
        let first = Task { await session.revoke(carol) }                 // #1 applied, reply delayed
        while await uplink.parkedCount < 1 { await Task.yield() }
        try await session.addViewer(carol, publicKey: keys[2].publicKey)   // relay: back on
        await uplink.setFailing(true)
        _ = await session.revoke(carol)                                  // #2 fails: she is still on the relay
        await uplink.setFailing(false)
        await uplink.release()
        _ = await first.value                                            // #1's stale "ok" arrives last
        _ = await session.flushOutbox()
        let onShare = await relay.viewers(of: share).contains(carol)
        XCTAssertFalse(onShare, "the latest intent (revoked) reached the relay")
        let pending = await session.unacknowledgedRevocations
        XCTAssertEqual(pending, [])
    }

    func testASlowReplyToAnOlderAddCannotClearANewerPendingAdd() async throws {
        let (session, uplink, relay, clock) = try await setUp()
        let dana = ViewerKeys(viewerID: ViewerID("d"))
        _ = await session.ingest(fix(0, clock), conditions: walking)
        await uplink.holdAfterNextAdd()
        let first = Task { try await session.addViewer(dana.viewerID, publicKey: dana.publicKey) }  // #1 applied, reply delayed
        while await uplink.parkedCount < 1 { await Task.yield() }
        _ = await session.revoke(dana.viewerID)                           // relay: off
        await uplink.setFailing(true)
        _ = try await session.addViewer(dana.viewerID, publicKey: dana.publicKey)  // #2 fails
        await uplink.setFailing(false)
        await uplink.release()
        _ = try await first.value                                        // #1's stale "ok" arrives last
        _ = await session.flushOutbox()
        let onShare = await relay.viewers(of: share).contains(dana.viewerID)
        XCTAssertTrue(onShare, "the latest intent (added) reached the relay")
        let pending = await session.unacknowledgedAdds
        XCTAssertEqual(pending, [])
    }

    func testARelayRefusalOfAnAddIsPermanentNotRetried() async throws {
        let clock = ManualClock(start: Instant(millis: 1_000_000))
        let relay = LocationRelay(configuration: RelayConfiguration(maxViewersPerShare: 3), clock: clock)
        try await relay.startShare(share, viewers: Set(keys.map(\.viewerID)), duration: .hours(1))
        var sealer = PerViewerSealer(shareID: share)
        for k in keys { try sealer.add(k.viewerID, publicKey: k.publicKey) }
        let session = try SharerSession(shareID: share, manifest: manifest, sealer: sealer, uplink: relay, clock: clock)
        let extra = ViewerKeys(viewerID: ViewerID("e"))
        do {
            try await session.addViewer(extra.viewerID, publicKey: extra.publicKey)
            XCTFail("expected tooManyViewers")
        } catch {
            XCTAssertEqual(error as? RelayError, .tooManyViewers(limit: 3))
        }
        let recipients = await session.recipients
        XCTAssertFalse(recipients.contains(extra.viewerID), "not sealed for a viewer the relay refused")
        let pending = await session.unacknowledgedAdds
        XCTAssertEqual(pending, [], "and not retried forever")
    }

    /// A session on a relay that holds at most three viewers, behind a `GatedUplink`.
    func setUpFullShare() async throws -> (SharerSession, GatedUplink, LocationRelay, ManualClock) {
        let clock = ManualClock(start: Instant(millis: 1_000_000))
        let relay = LocationRelay(configuration: RelayConfiguration(maxViewersPerShare: 3), clock: clock)
        try await relay.startShare(share, viewers: Set(keys.map(\.viewerID)), duration: .hours(1))
        var sealer = PerViewerSealer(shareID: share)
        for k in keys { try sealer.add(k.viewerID, publicKey: k.publicKey) }
        let uplink = GatedUplink(relay: relay)
        let session = try SharerSession(shareID: share, manifest: manifest, sealer: sealer, uplink: uplink, clock: clock)
        return (session, uplink, relay, clock)
    }

    func testAStaleRefusalCannotDropAViewerReAddedAfterASlotFreedUp() async throws {
        let (session, uplink, relay, _) = try await setUpFullShare()
        let erin = ViewerKeys(viewerID: ViewerID("e"))
        await uplink.holdAfterNextAdd()
        let first = Task { try await session.addViewer(erin.viewerID, publicKey: erin.publicKey) }  // refused (full), reply delayed
        while await uplink.parkedCount < 1 { await Task.yield() }
        _ = await session.revoke(keys[0].viewerID)                        // frees a slot at the relay
        let off = await session.revoke(erin.viewerID)                     // parks behind #1
        let again = try await session.addViewer(erin.viewerID, publicKey: erin.publicKey)  // parks too: "pending"
        XCTAssertFalse(off)
        XCTAssertFalse(again, "pending, not yet acknowledged")
        await uplink.release()                                           // #1's refusal arrives: it answers an old intent
        let firstResult = try await first.value
        XCTAssertTrue(firstResult, "the reconciler sent the latest intent, and the relay accepted it")
        let onRelay = await relay.viewers(of: share).contains(erin.viewerID)
        XCTAssertTrue(onRelay)
        let recipients = await session.recipients
        XCTAssertTrue(recipients.contains(erin.viewerID), "still sealed for")
        let pending = await session.unacknowledgedAdds
        XCTAssertEqual(pending, [])
        let refused = await session.refusedAdds
        XCTAssertEqual(refused, [:])
    }

    func testARefusalMetByAFlushRetryIsReported() async throws {
        let (session, uplink, _, _) = try await setUpFullShare()
        let erin = ViewerKeys(viewerID: ViewerID("e"))
        await uplink.setFailing(true)
        let acknowledged = try await session.addViewer(erin.viewerID, publicKey: erin.publicKey)
        XCTAssertFalse(acknowledged, "offline: pending")
        await uplink.setFailing(false)
        _ = await session.flushOutbox()                                  // the retry is refused: share is full
        let refused = await session.refusedAdds
        XCTAssertEqual(refused, [erin.viewerID: .tooManyViewers(limit: 3)])
        let pending = await session.unacknowledgedAdds
        XCTAssertEqual(pending, [])
        let recipients = await session.recipients
        XCTAssertFalse(recipients.contains(erin.viewerID))
    }

    func testAnAddOverlappingStopThrowsShareEnded() async throws {
        let (session, uplink, _, _) = try await setUp()
        let dana = ViewerKeys(viewerID: ViewerID("d"))
        await uplink.holdAfterNextAdd()
        let adding = Task { try await session.addViewer(dana.viewerID, publicKey: dana.publicKey) }
        while await uplink.parkedCount < 1 { await Task.yield() }
        _ = await session.stop()
        await uplink.release()
        do {
            _ = try await adding.value
            XCTFail("expected shareEnded")
        } catch {
            XCTAssertEqual(error as? SessionError, .shareEnded)
        }
    }

    func testRevokeAndStopTreatAnUnknownShareAsDone() async throws {
        let (session, uplink, _, clock) = try await setUp()
        _ = await session.ingest(fix(0, clock), conditions: walking)
        await uplink.setUnknownShareOnCleanup(true)                       // the relay already forgot the share
        let revoked = await session.revoke(keys[0].viewerID)
        XCTAssertTrue(revoked, "nothing left to delete counts as done")
        let pending = await session.unacknowledgedRevocations
        XCTAssertEqual(pending, [], "so the 1 s timer is not retrying it forever")
        let stopped = await session.stop()
        XCTAssertTrue(stopped)
        let stopPending = await session.stopUnacknowledged
        XCTAssertFalse(stopPending)
    }

    func flushWithStopDuringUpload(uploadSucceeds: Bool) async throws -> IngestOutcome {
        let (session, uplink, _, clock) = try await setUp()
        await uplink.setFailing(true)
        _ = await session.ingest(fix(0, clock), conditions: walking)     // held offline
        await uplink.setFailing(false)
        await uplink.holdNextUpload()
        let flushing = Task { await session.flushOutbox() }
        while await uplink.uploads.count < 2 { await Task.yield() }
        await uplink.setFailing(true)
        _ = await session.stop()                                         // runs at the flush's await
        await uplink.setFailing(!uploadSucceeds)
        await uplink.release()
        return await flushing.value
    }

    func testFlushReturnsEndedWhenStopRunsDuringASuccessfulUpload() async throws {
        let outcome = try await flushWithStopDuringUpload(uploadSucceeds: true)
        XCTAssertEqual(outcome, .ended)
    }

    func testFlushReturnsEndedWhenStopRunsDuringAFailedUpload() async throws {
        let outcome = try await flushWithStopDuringUpload(uploadSucceeds: false)
        XCTAssertEqual(outcome, .ended, "not .heldOffline: the outbox was already cleared by stop()")
    }

    func testAFailedSealDoesNotResetTheHeartbeatClock() async throws {
        let (session, _, relay, clock) = try await setUp()
        _ = await session.ingest(fix(0, clock), conditions: walking)     // committed at t0
        for k in keys { _ = await session.revoke(k.viewerID) }           // nobody to seal for
        clock.advance(by: .seconds(61))
        let nobody = await session.tick(conditions: walking)
        XCTAssertEqual(nobody, .idle, "nothing sealed")
        try await relay.addViewer(keys[0].viewerID, to: share)
        try await session.addViewer(keys[0].viewerID, publicKey: keys[0].publicKey)
        clock.advance(by: .seconds(1))
        let beat = await session.tick(conditions: walking)
        guard case .published(.heartbeat, _, _) = beat else {
            return XCTFail("the heartbeat is still owed from t0, so the empty seal did not commit: \(beat)")
        }
    }

    func testRelayCallsForOneViewerAreSingleFlight() async throws {
        let (session, uplink, relay, clock) = try await setUp()
        let carol = ViewerID("c")
        _ = await session.ingest(fix(0, clock), conditions: walking)
        await uplink.holdNextRevoke()
        let first = Task { await session.revoke(carol) }                 // in flight, parked
        while await uplink.revokeCalls < 1 { await Task.yield() }
        let second = await session.revoke(carol)                         // a double tap…
        let flushed = await session.flushOutbox()                        // …and the 1 s timer, meanwhile
        XCTAssertFalse(second, "pending: another call for Carol is in flight")
        _ = flushed
        await uplink.release()
        let firstResult = await first.value
        XCTAssertTrue(firstResult)
        let calls = await uplink.revokeCalls
        XCTAssertEqual(calls, 1, "one relay call, not one per caller — and no ping-pong")
        let onShare = await relay.viewers(of: share).contains(carol)
        XCTAssertFalse(onShare)
        let pending = await session.unacknowledgedRevocations
        XCTAssertEqual(pending, [])
    }

    func testStopDuringAFailingUploadNeverRefillsTheOutbox() async throws {
        let (session, uplink, _, clock) = try await setUp()
        _ = await session.ingest(fix(0, clock), conditions: walking)
        clock.advance(by: .seconds(20))
        await uplink.holdNextUpload()
        let f = fix(0.001, clock), conditions = walking
        let inFlight = Task { await session.ingest(f, conditions: conditions) }
        while await uplink.uploads.count < 2 { await Task.yield() }
        await uplink.setFailing(true)
        _ = await session.stop()
        await uplink.release()
        let outcome = await inFlight.value
        XCTAssertEqual(outcome, .ended)
        let held = await session.heldBatchRecipients
        XCTAssertEqual(held, [])
    }

    func testOfflineOutboxKeepsOnlyTheNewestBatch() async throws {
        let (session, uplink, relay, clock) = try await setUp()
        await uplink.setFailing(true)
        let first = await session.ingest(fix(0, clock), conditions: walking)
        clock.advance(by: .seconds(20))
        let second = await session.ingest(fix(0.001, clock), conditions: walking)
        XCTAssertEqual(first, .heldOffline(sequence: 1))
        XCTAssertEqual(second, .heldOffline(sequence: 2))
        await uplink.setFailing(false)
        let flushed = await session.flushOutbox()
        guard case .published(.moved, let seq, _) = flushed else { return XCTFail("\(flushed)") }
        XCTAssertEqual(seq, 2)
        let uploads = await uplink.uploads
        XCTAssertEqual(uploads.last?.map(\.sequence), [2, 2, 2], "one batch, the newest, to all three viewers")
        let again = await session.flushOutbox()
        XCTAssertEqual(again, .idle)
        let stored = await relay.stats.storedPoints
        XCTAssertEqual(stored, 3)
    }

    func testBudgetRunsDryButHeartbeatsContinue() async throws {
        let (session, _, _, clock) = try await setUp(budget: 2)
        var lat = 0.0
        var outcomes: [IngestOutcome] = []
        for _ in 0..<6 {
            lat += 0.001
            outcomes.append(await session.ingest(fix(lat, clock), conditions: walking))
            clock.advance(by: .seconds(20))
        }
        let reasons = outcomes.map { o -> String in
            switch o {
            case .published(let r, _, _): return r.rawValue
            case .suppressed(let s): return s.rawValue
            default: return "other"
            }
        }
        // Fixes every 20 s: two movement tokens, then suppressed until the 60 s heartbeat is owed.
        XCTAssertEqual(reasons, ["first", "moved", "moved", "budgetExhausted", "budgetExhausted", "heartbeat"])
        let remaining = await session.budgetRemaining
        XCTAssertEqual(remaining, 0)
    }

    func testTickRepublishesTheLastFixWithAFreshSentAt() async throws {
        let (session, _, relay, clock) = try await setUp()
        var opener = PerViewerOpener(keys: keys[0])
        opener.trust(share, sharerPublicKey: sealer.sharePublicKey)
        let initial = await session.tick(conditions: walking)
        XCTAssertEqual(initial, .idle, "nothing published yet, nothing to heartbeat")
        _ = await session.ingest(fix(0.5, clock), conditions: walking)
        let firstSent = clock.now()
        clock.advance(by: .seconds(59))
        let early = await session.tick(conditions: walking)
        XCTAssertEqual(early, .idle)
        clock.advance(by: .seconds(1))
        let beat = await session.tick(conditions: walking)
        guard case .published(.heartbeat, _, _) = beat else { return XCTFail("\(beat)") }
        let latest = await relay.latest(share, for: keys[0].viewerID)
        let stored = try XCTUnwrap(latest)
        let payload = try opener.open(stored)
        XCTAssertEqual(payload.fix.latitude, 0.5)
        XCTAssertEqual(payload.fix.timestamp, firstSent, "position age is honest: the fix is the old one")
        XCTAssertEqual(payload.sentAt, clock.now(), "presence age is fresh")
    }
}

final class PresenceInvariantTests: XCTestCase {
    /// Drives a stationary sharer for 10 minutes against the real relay and counts seconds in which the
    /// relay reports `.away`. The cadence function is injected so a broken policy can be fed in.
    func awaySeconds(dropEveryOtherHeartbeat: Bool = false,
                     cadence: (DeviceConditions, Millis) -> PublishCadence) async throws -> Int {
        let clock = ManualClock()
        let ttl = Millis.seconds(120)
        let relay = LocationRelay(configuration: RelayConfiguration(presenceTTL: ttl), clock: clock)
        let share = ShareID("p")
        try await relay.startShare(share, viewers: [ViewerID("v")], duration: .hours(1))
        var gate = PublishGate()
        var seq: UInt64 = 0
        var away = 0
        let parked = DeviceConditions(batteryLevel: 0.05, isLowPowerMode: true, motion: .stationary)
        let spot = try XCTUnwrap(LocationFix(latitude: 1, longitude: 1, accuracyMeters: 5, timestamp: clock.now()))
        var beats = 0
        for second in 0..<600 {
            let c = cadence(parked, ttl)
            if second == 0 || gate.heartbeatDue(now: clock.now(), cadence: c) {
                seq += 1
                beats += 1
                gate.commit(spot, at: clock.now())
                let lost = dropEveryOtherHeartbeat && beats % 2 == 0
                if !lost { _ = await relay.publish([sealedCopy("p", "v", seq)]) }
            }
            if case .away = await relay.presence(of: share) { away += 1 }
            clock.advance(by: .seconds(1))
        }
        return away
    }

    func testRealPolicyNeverLetsPresenceLapseForAnOnlineSharer() async throws {
        let away = try await awaySeconds { PublishPolicy.cadence(for: $0, presenceTTL: $1) }
        XCTAssertEqual(away, 0)
    }

    func testOneLostHeartbeatInARowStillNeverLetsPresenceLapse() async throws {
        // The TTL / 2 rationale: lose every other heartbeat and the next one still lands within the TTL.
        let away = try await awaySeconds(dropEveryOtherHeartbeat: true) { PublishPolicy.cadence(for: $0, presenceTTL: $1) }
        XCTAssertEqual(away, 0)
        // Control: a heartbeat just under the TTL (the weaker "strictly shorter" rule) fails the same test.
        let weak = try await awaySeconds(dropEveryOtherHeartbeat: true) { c, ttl in
            let real = PublishPolicy.cadence(for: c, presenceTTL: ttl)
            return PublishCadence(minInterval: real.minInterval, minDistanceMeters: real.minDistanceMeters,
                                  heartbeatInterval: Millis(ttl.value - 1_000))
        }
        XCTAssertGreaterThan(weak, 0)
    }

    func testTheCheckCatchesAPolicyWhoseHeartbeatOutlivesTheTTL() async throws {
        // The obvious "save battery when parked" bug: scale the heartbeat with the battery multiplier too.
        let away = try await awaySeconds { c, ttl in
            let real = PublishPolicy.cadence(for: c, presenceTTL: ttl)
            return PublishCadence(minInterval: real.minInterval, minDistanceMeters: real.minDistanceMeters,
                                  heartbeatInterval: real.heartbeatInterval.times(PublishPolicy.batteryMultiplier(c)))
        }
        XCTAssertGreaterThan(away, 0, "if this ever passes at 0, the presence check above proves nothing")
    }
}

final class FreshnessTests: XCTestCase {
    let hb = Millis.seconds(60), ttl = Millis.seconds(120)

    func classify(age: Int64?, offline: Bool = false, ended: Bool = false) -> Freshness {
        let now = Instant(millis: 1_000_000)
        return Freshness.classify(lastSentAt: age.map { Instant(millis: now.millis - $0 * 1_000) }, now: now,
                                  heartbeat: hb, presenceTTL: ttl, isViewerOffline: offline, hasEnded: ended)
    }

    func testBoundaries() {
        XCTAssertEqual(classify(age: nil), .waiting)
        XCTAssertEqual(classify(age: 0), .live(age: .zero))
        XCTAssertEqual(classify(age: 90), .live(age: .seconds(90)))
        XCTAssertEqual(classify(age: 91), .delayed(age: .seconds(91)))
        XCTAssertEqual(classify(age: 120), .delayed(age: .seconds(120)))
        XCTAssertEqual(classify(age: 121), .stale(age: .seconds(121)))
    }

    func testAnOldCopyFromAnOnlineSharerIsBehindNotStale() {
        let now = Instant(millis: 1_000_000)
        let f = Freshness.classify(lastSentAt: Instant(millis: now.millis - 360_000), now: now, heartbeat: hb,
                                   presenceTTL: ttl, isViewerOffline: false, hasEnded: false, sharerOnline: true)
        XCTAssertEqual(f, .behind(age: .seconds(360)))
        XCTAssertEqual(f.label, "Updated 6m ago · sharer online")
        XCTAssertEqual(classify(age: 360), .stale(age: .seconds(360)), "without presence it stays stale")
    }

    func testViewerOfflineAndEndedWinOverAge() {
        XCTAssertEqual(classify(age: 5, offline: true), .offline(lastKnownAge: .seconds(5)))
        XCTAssertEqual(classify(age: nil, offline: true), .offline(lastKnownAge: nil))
        XCTAssertEqual(classify(age: 5, offline: true, ended: true), .ended)
        XCTAssertEqual(classify(age: 400).label, "Last seen 6m ago")
    }
}

final class LoadModelTests: XCTestCase {
    func testReferenceNumbersMatchAHandCalculation() {
        // Hand calc: Hz/sharer = .55/60 + .20/15 + .05/10 + .20/5 = 0.0675 (stationary at its 60 s heartbeat).
        let e = FanoutLoadModel.estimate(.reference(copyBytes: 200))
        XCTAssertEqual(e.publishesPerSecond, 67.5, accuracy: 1e-9)
        XCTAssertEqual(e.copiesPerSecond, 202.5, accuracy: 1e-9)
        XCTAssertEqual(e.socketMessagesPerSecond, 60.75, accuracy: 1e-9)
        XCTAssertEqual(e.ingressBytesPerSecond, 40_500, accuracy: 1e-6)
        XCTAssertEqual(e.naiveCopiesPerSecond, 3_000, accuracy: 1e-9)
        // 2,100 background viewers × 243 pushes/h vs × 12/h (one per 5 min).
        XCTAssertEqual(e.pushesPerHourUnbudgeted, 510_300, accuracy: 1e-6)
        XCTAssertEqual(e.pushesPerHourBudgeted, 25_200, accuracy: 1e-6)
        XCTAssertEqual(e.storedBytes, 600_000)
    }

    func testHostileInputsGiveFiniteNonNegativeOutput() {
        let e = FanoutLoadModel.estimate(LoadAssumptions(activeShares: -5, meanViewersPerShare: .nan, motionMix: [.walking: -.infinity],
                                                         foregroundFraction: 7, copyBytes: -1, presenceTTL: .zero, pushRefill: .zero))
        for v in [e.publishesPerSecond, e.copiesPerSecond, e.socketMessagesPerSecond, e.pushesPerHourUnbudgeted,
                  e.pushesPerHourBudgeted, e.ingressBytesPerSecond, e.naiveCopiesPerSecond, e.foregroundConnections,
                  e.backgroundViewers] {
            XCTAssertTrue(v.isFinite && v >= 0)
        }
        XCTAssertEqual(e.storedBytes, 0)
        let huge = FanoutLoadModel.estimate(LoadAssumptions(activeShares: .max, meanViewersPerShare: 1e300, motionMix: [.driving: 1],
                                                            foregroundFraction: 0.5, copyBytes: .max, presenceTTL: .seconds(120), pushRefill: .minutes(5)))
        XCTAssertEqual(huge.storedBytes, .max, "saturates instead of trapping in Int(Double)")
        XCTAssertGreaterThan(huge.copiesPerSecond, 0, "an overflowing estimate clamps high, never reads as zero load")
    }

    func testABudgetLooserThanThePublishRateChangesNothing() {
        // Driving publishes every 5 s (720/h per viewer). A 1 s refill (3,600/h) never binds; a 5 min refill does.
        let loose = FanoutLoadModel.estimate(LoadAssumptions(activeShares: 1_000, meanViewersPerShare: 3, motionMix: [.driving: 1],
                                                             foregroundFraction: 0, copyBytes: 200, presenceTTL: .seconds(120),
                                                             pushRefill: .seconds(1)))
        XCTAssertEqual(loose.pushesPerHourBudgeted, loose.pushesPerHourUnbudgeted, accuracy: 1e-6)
        XCTAssertEqual(loose.pushesPerHourUnbudgeted, 3_000 * 720, accuracy: 1e-6)
        let tight = FanoutLoadModel.estimate(LoadAssumptions(activeShares: 1_000, meanViewersPerShare: 3, motionMix: [.driving: 1],
                                                             foregroundFraction: 0, copyBytes: 200, presenceTTL: .seconds(120),
                                                             pushRefill: .minutes(5)))
        XCTAssertEqual(tight.pushesPerHourBudgeted, 3_000 * 12, accuracy: 1e-6)
    }

    func testTenMillionSharesFiguresQuotedInTheREADME() {
        let e = FanoutLoadModel.estimate(.reference(copyBytes: 365, activeShares: 10_000_000))
        XCTAssertEqual(e.publishesPerSecond, 675_000, accuracy: 1e-3)
        XCTAssertEqual(e.copiesPerSecond, 2_025_000, accuracy: 1e-3)
        XCTAssertEqual(e.foregroundConnections, 9_000_000, accuracy: 1e-3)
        XCTAssertEqual(e.backgroundViewers, 21_000_000, accuracy: 1e-3)
        XCTAssertEqual(e.pushesPerHourBudgeted, 252_000_000, accuracy: 1e-1)
        XCTAssertEqual(e.ingressBytesPerSecond, 739_125_000, accuracy: 1)
        XCTAssertEqual(e.storedBytes, 10_950_000_000)
    }
}

final class AgeRatingGateTests: XCTestCase {
    func testAllFourCombinations() {
        let sharing = CapabilityManifest(capabilities: [.liveLocationSharing, .locationForAppFeatures])
        let mapsOnly = CapabilityManifest(capabilities: [.locationForAppFeatures])
        XCTAssertEqual(AgeRatingGate.check(manifest: sharing, declaration: .init(sharedLocation: false)), [.undeclaredSharedLocation])
        XCTAssertEqual(AgeRatingGate.check(manifest: sharing, declaration: .init(sharedLocation: true)), [])
        XCTAssertEqual(AgeRatingGate.check(manifest: mapsOnly, declaration: .init(sharedLocation: true)), [.overDeclaredSharedLocation])
        XCTAssertEqual(AgeRatingGate.check(manifest: mapsOnly, declaration: .init(sharedLocation: false)), [])
        XCTAssertTrue(AgeRatingDrift.undeclaredSharedLocation.isBlocking)
        XCTAssertFalse(AgeRatingDrift.overDeclaredSharedLocation.isBlocking)
    }

    func testDecodesTheCheckedInJSONShapes() throws {
        let m = try CapabilityManifest.decode(Data(#"{"capabilities":["liveLocationSharing"]}"#.utf8))
        let d = try AgeRatingDeclaration.decode(Data(#"{"sharedLocation":false}"#.utf8))
        XCTAssertEqual(AgeRatingGate.check(manifest: m, declaration: d), [.undeclaredSharedLocation])
        XCTAssertThrowsError(try CapabilityManifest.decode(Data(#"{"capabilities":["teleportation"]}"#.utf8)),
                             "an unknown capability is a decode error, not silently ignored")
    }
}
