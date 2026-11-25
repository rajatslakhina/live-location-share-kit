import Foundation
import Observation
import LiveLocation

/// An uplink that can be switched off, to show the latest-wins outbox. Wraps the real relay.
actor SwitchableUplink: RelayUplink {
    let relay: LocationRelay
    var isDown = false
    nonisolated let presenceTTL: Millis
    init(relay: LocationRelay) { self.relay = relay; self.presenceTTL = relay.configuration.presenceTTL }
    func setDown(_ down: Bool) { isDown = down }
    func upload(_ copies: [SealedPoint]) async throws -> PublishReceipt {
        if isDown { throw URLError(.notConnectedToInternet) }
        return await relay.publish(copies)
    }
    func revoke(_ viewer: ViewerID, from share: ShareID) async throws {
        if isDown { throw URLError(.notConnectedToInternet) }
        await relay.revoke(viewer, from: share)
    }
    func addViewer(_ viewer: ViewerID, to share: ShareID) async throws { try await relay.addViewer(viewer, to: share) }
    func stop(_ share: ShareID) async throws { await relay.stopShare(share) }
}

/// One viewer as the demo renders them.
public struct ViewerRow: Identifiable, Hashable, Sendable {
    public enum Channel: String, Sendable { case socket = "Foreground · WebSocket", push = "Background · push", revoked = "Revoked" }
    public let id: ViewerID
    public let name: String
    public let channel: Channel
    public let freshness: Freshness
    public let latitude: Double?
    public let longitude: Double?
    public let received: Int
    public let rejected: Int
}

public struct RoutePoint: Hashable, Sendable {
    public let latitude: Double
    public let longitude: Double
}

public struct TimelineEntry: Identifiable, Hashable, Sendable {
    public let id: Int
    public let minute: String
    public let text: String
}

/// Drives a deterministic 12-minute scenario through the real library types: `SharerSession` →
/// `PerViewerSealer` → `LocationRelay` → (stream | budgeted push) → `PointInbox` per viewer.
///
/// It lives in the package (not the app) so its numbers are covered by `LiveLocationUITests` — the
/// demo README quotes them, and a test fails if they drift.
@MainActor
@Observable
public final class ScenarioModel {
    public static let scenarioMinutes: Int64 = 12
    /// Deliberately small so the scenario visibly runs the battery budget dry while driving.
    public static let demoBudget = 24
    /// Seconds at which the script injects one poor-accuracy fix and one re-delivered (older) fix.
    static let inaccurateFixSecond: Int64 = 100
    static let reorderedFixSecond: Int64 = 130

    public let manifest: CapabilityManifest
    public let declaration: AgeRatingDeclaration
    public private(set) var isRunning = false
    public private(set) var finished = false
    public private(set) var counters = SessionCounters()
    public private(set) var cadence: PublishCadence?
    public private(set) var budgetRemaining = 0
    public private(set) var relayStats: RelayStats?
    public private(set) var viewers: [ViewerRow] = []
    public private(set) var timeline: [TimelineEntry] = []
    public private(set) var sampleCiphertext = ""
    public private(set) var route: [RoutePoint] = []
    public private(set) var copyBytes = 0
    public private(set) var flushedAfterOutage = false
    public private(set) var refusal = ""

    private let clock = ManualClock(start: Instant(millis: 1_764_000_000_000))
    /// Random, so the relay learns nothing from the identifier itself.
    private let shareID = ShareID(UUID().uuidString)
    private let config = RelayConfiguration(presenceTTL: .seconds(120), pushBurst: 4, pushRefill: .minutes(6))
    private var inboxes: [ViewerID: PointInbox] = [:]
    private var receivedCount: [ViewerID: Int] = [:]
    private var rejectedCount: [ViewerID: Int] = [:]
    private var expectedLive: [ViewerID: Int] = [:]
    private var revoked: Set<ViewerID> = []
    private var consumers: [Task<Void, Never>] = []
    private var sharerOnline = false
    private var budgetRanDry = false

    let alice = ViewerID("alice"), bob = ViewerID("bob"), carol = ViewerID("carol")
    private let names: [ViewerID: String]

    /// - Parameters:
    ///   - manifest: the app's capability manifest. Without `.liveLocationSharing` the session refuses to start.
    ///   - declaration: the app's exported App Store Connect answer, shown on the Age rating tab.
    public init(manifest: CapabilityManifest, declaration: AgeRatingDeclaration) {
        self.manifest = manifest
        self.declaration = declaration
        self.names = [alice: "Alice", bob: "Bob", carol: "Carol"]
    }

    public var presenceTTL: Millis { config.presenceTTL }
    public var pushRefill: Millis { config.pushRefill }

    /// Runs the whole scenario once. Safe to call repeatedly; later calls are ignored.
    public func runIfNeeded() async {
        guard !isRunning, !finished else { return }
        isRunning = true
        defer { isRunning = false; finished = true }
        refusal = Self.runtimeRefusal()

        let relay = LocationRelay(configuration: config, clock: clock)
        let uplink = SwitchableUplink(relay: relay)
        var sealer = PerViewerSealer(shareID: shareID)
        for id in [alice, bob, carol] {
            let keys = ViewerKeys(viewerID: id)
            var inbox = PointInbox(opener: PerViewerOpener(keys: keys))
            // The invitation carries the share's public key out of band; viewers pin it.
            inbox.trust(shareID, sharerPublicKey: sealer.sharePublicKey)
            inboxes[id] = inbox
            do { try sealer.add(id, publicKey: keys.publicKey) } catch { log(0, "Bad key for \(id)"); return }
        }
        let session: SharerSession
        do {
            try await relay.startShare(shareID, viewers: [alice, bob, carol], duration: .hours(1))
            session = try SharerSession(shareID: shareID, manifest: manifest, sealer: sealer, uplink: uplink,
                                        clock: clock, discretionaryBudget: Self.demoBudget, budgetRefill: .seconds(60))
        } catch {
            log(0, "Session refused: \(error)")
            return
        }
        log(0, "Share started · 3 viewers · expires in 60 min")

        // Alice and Carol keep the app open (WebSocket path). Bob is backgrounded (push path).
        for id in [alice, carol] {
            guard let connection = try? await relay.connect(id) else { log(0, "Could not connect \(id)"); return }
            consumers.append(Task { @MainActor [weak self] in
                for await point in connection.points { self?.receive(point, for: id) }
            })
            consumers.append(Task { @MainActor [weak self] in
                for await event in connection.control { self?.control(event, for: id) }
            })
        }

        let totalSeconds = Self.scenarioMinutes * 60
        var lat = 37.7793, lon = -122.4193
        for second in 0..<totalSeconds {
            clock.advance(by: .seconds(1))
            let minute = second / 60
            let motion: MotionState = minute < 3 ? .walking : (minute < 7 ? .driving : .stationary)
            switch motion {
            case .walking: lat += 1.4 / 111_000
            case .driving: lon += 12 / 88_000
            default: break
            }
            if second % 5 == 0 { route.append(RoutePoint(latitude: lat, longitude: lon)) }
            let battery = second < 9 * 60 ? 0.62 - Double(second) * 0.0006 : 0.18
            let conditions = DeviceConditions(batteryLevel: battery, motion: motion)

            if second == 5 * 60 + 30 {
                let acknowledged = await session.revoke(carol)
                revoked.insert(carol)
                log(second, "Carol revoked: sharer stops sealing for her; relay \(acknowledged ? "deleted" : "will delete") her copy")
            }
            if second == 8 * 60 { await uplink.setDown(true); log(second, "Sharer loses network") }
            if second == 9 * 60 {
                await uplink.setDown(false)
                if case .published(_, _, let receipt) = await session.flushOutbox() {
                    flushedAfterOutage = true
                    for v in receipt.deliveredLive { expectedLive[v, default: 0] += 1 }
                }
                log(second, "Network back: latest-wins outbox flushed (\(flushedAfterOutage ? "1 batch" : "nothing held"))")
            }

            // Stationary devices stop producing fresh fixes; the heartbeat timer carries presence.
            let outcome: IngestOutcome
            if motion == .stationary {
                outcome = await session.tick(conditions: conditions)
            } else if second == Self.reorderedFixSecond,
                      let stale = LocationFix(latitude: lat - 0.0005, longitude: lon, accuracyMeters: 8,
                                              timestamp: Instant(millis: clock.now().millis - 45_000)) {
                // A fix stamped 45 s ago arriving now (CoreLocation can re-deliver): older than the last
                // published point, so the gate must drop it.
                outcome = await session.ingest(stale, conditions: conditions)
                if outcome == .suppressed(.outOfOrder) { log(second, "Re-delivered older fix dropped (out of order)") }
            } else {
                let accuracy = second == Self.inaccurateFixSecond ? 650.0 : 8.0
                guard let fix = LocationFix(latitude: lat, longitude: lon, accuracyMeters: accuracy, timestamp: clock.now())
                else { continue }
                outcome = await session.ingest(fix, conditions: conditions)
                if outcome == .suppressed(.inaccurate) { log(second, "650 m fix ignored (accuracy)") }
            }
            if case .published(let reason, _, let receipt) = outcome {
                for v in receipt.deliveredLive { expectedLive[v, default: 0] += 1 }
                // Log the first point and every heartbeat; movement updates are summarised on the Sharer tab.
                if reason != .moved {
                    log(second, "\(reason.rawValue) → live \(receipt.deliveredLive.count), push-queued \(receipt.queuedForPush.count)")
                }
            }
            if case .heldOffline = outcome { log(second, "Heartbeat held offline (outbox keeps newest only)") }
            if outcome == .suppressed(.budgetExhausted), !budgetRanDry {
                budgetRanDry = true
                log(second, "Battery budget spent: movement updates paused, heartbeats continue")
            }

            if second % 30 == 0 {
                for push in await relay.drainPushes() {
                    receive(push.sealed, for: push.viewer, viaPush: true)
                    let noun = push.coalesced == 1 ? "point" : "points"
                    log(second, push.coalesced > 0
                        ? "Push to \(names[push.viewer] ?? "?") carried the newest point, replacing \(push.coalesced) older \(noun)"
                        : "Push to \(names[push.viewer] ?? "?")")
                }
            }
            await Task.yield()
        }

        counters = await session.counters
        cadence = await session.lastCadence
        budgetRemaining = await session.budgetRemaining
        relayStats = await relay.stats
        if let sample = await relay.latest(shareID, for: alice) {
            copyBytes = sample.approximateByteCount
            // Skip the 12-byte nonce so the card shows ciphertext proper.
            sampleCiphertext = sample.ciphertext.dropFirst(12).prefix(18).map { String(format: "%02x", $0) }.joined()
        }
        // Wait (bounded) until every live delivery has been consumed, so the final render is deterministic.
        for _ in 0..<10_000 {
            let drained = [alice, carol].allSatisfy {
                (receivedCount[$0] ?? 0) + (rejectedCount[$0] ?? 0) >= (expectedLive[$0] ?? 0)
            }
            if drained { break }
            await Task.yield()
        }
        consumers.forEach { $0.cancel() }
        // Forget ended shares only now, after every buffered point was consumed, so counts never depend
        // on how the points and control tasks happened to interleave.
        for viewer in revoked { inboxes[viewer]?.forget(shareID) }
        if case .online = await relay.presence(of: shareID) { sharerOnline = true }
        refreshViewers()
        log(Self.scenarioMinutes * 60, "Scenario complete")
    }

    private func receive(_ sealed: SealedPoint, for viewer: ViewerID, viaPush: Bool = false) {
        guard var inbox = inboxes[viewer] else { return }
        do {
            try inbox.receive(sealed)
            receivedCount[viewer, default: 0] += 1
        } catch {
            rejectedCount[viewer, default: 0] += 1
        }
        inboxes[viewer] = inbox
        if viaPush { refreshViewers() }
    }

    private func control(_ event: ControlEvent, for viewer: ViewerID) {
        switch event {
        case .revoked, .ended:
            revoked.insert(viewer)          // the pin is removed now; the inbox is forgotten after draining
        }
    }

    private func refreshViewers() {
        let now = clock.now()
        viewers = [alice, bob, carol].map { id in
            let latest = inboxes[id]?.latest[shareID]?.payload
            let gone = revoked.contains(id)
            let fresh = Freshness.classify(lastSentAt: latest?.sentAt, now: now,
                                           heartbeat: config.presenceTTL.dividedBy(2), presenceTTL: config.presenceTTL,
                                           isViewerOffline: false, hasEnded: gone, sharerOnline: sharerOnline)
            return ViewerRow(id: id, name: names[id] ?? id.raw,
                             channel: gone ? .revoked : (id == bob ? .push : .socket),
                             freshness: fresh,
                             latitude: gone ? nil : latest?.fix.latitude, longitude: gone ? nil : latest?.fix.longitude,
                             received: receivedCount[id] ?? 0, rejected: rejectedCount[id] ?? 0)
        }
    }

    private func log(_ second: Int64, _ text: String) {
        let m = second / 60, s = second % 60
        let stamp = (m < 10 ? "0\(m)" : "\(m)") + ":" + (s < 10 ? "0\(s)" : "\(s)")
        timeline.append(TimelineEntry(id: timeline.count, minute: stamp, text: text))
    }

    /// The runtime half of the age-rating rule: a session built from a manifest *without*
    /// `.liveLocationSharing` must refuse to exist.
    static func runtimeRefusal() -> String {
        do {
            _ = try SharerSession(shareID: ShareID("probe"), manifest: CapabilityManifest(capabilities: [.locationForAppFeatures]),
                                  sealer: PerViewerSealer(shareID: ShareID("probe")), uplink: LocationRelay(),
                                  clock: ManualClock())
            return "started (the gate is broken)"
        } catch {
            return "refused (\(error))"
        }
    }
}
