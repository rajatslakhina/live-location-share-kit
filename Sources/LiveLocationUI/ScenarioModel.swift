import Foundation
import Observation
import LiveLocation

/// An uplink that can be switched off, to show the latest-wins outbox. Wraps the real relay.
actor SwitchableUplink: RelayUplink {
    let relay: LocationRelay
    var isDown = false
    init(relay: LocationRelay) { self.relay = relay }
    func setDown(_ down: Bool) { isDown = down }
    func upload(_ copies: [SealedPoint]) async throws -> PublishReceipt {
        if isDown { throw URLError(.notConnectedToInternet) }
        return await relay.publish(copies)
    }
    func revoke(_ viewer: ViewerID, from share: ShareID) async throws {
        await relay.revoke(viewer, from: share)
    }
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
@MainActor
@Observable
public final class ScenarioModel {
    public static let scenarioMinutes: Int64 = 12
    /// Deliberately small so the scenario visibly runs the battery budget dry while driving.
    public static let demoBudget = 24

    public let manifest: CapabilityManifest
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

    private let clock = ManualClock(start: Instant(millis: 1_764_000_000_000))
    private let shareID = ShareID("share-rajat-commute")
    private let config = RelayConfiguration(presenceTTL: .seconds(120), pushBurst: 4, pushRefill: .minutes(5))
    private var inboxes: [ViewerID: PointInbox] = [:]
    private var receivedCount: [ViewerID: Int] = [:]
    private var rejectedCount: [ViewerID: Int] = [:]
    private var revoked: Set<ViewerID> = []
    private var consumers: [Task<Void, Never>] = []

    let alice = ViewerID("alice"), bob = ViewerID("bob"), carol = ViewerID("carol")
    private let names: [ViewerID: String]

    /// - Parameter manifest: the app's capability manifest. The demo app passes its compiled-in copy;
    ///   without `.liveLocationSharing` the session refuses to start.
    public init(manifest: CapabilityManifest) {
        self.manifest = manifest
        self.names = [alice: "Alice", bob: "Bob", carol: "Carol"]
    }

    public var presenceTTL: Millis { config.presenceTTL }
    public var pushRefill: Millis { config.pushRefill }

    /// Runs the whole scenario once. Safe to call repeatedly; later calls are ignored.
    public func runIfNeeded() async {
        guard !isRunning, !finished else { return }
        isRunning = true
        defer { isRunning = false; finished = true }

        let relay = LocationRelay(configuration: config, clock: clock)
        let uplink = SwitchableUplink(relay: relay)
        var sealer = PerViewerSealer(shareID: shareID)
        for id in [alice, bob, carol] {
            let keys = ViewerKeys(viewerID: id)
            inboxes[id] = PointInbox(opener: PerViewerOpener(keys: keys))
            do { try sealer.add(id, publicKey: keys.publicKey) } catch { log(0, "Bad key for \(id)"); return }
        }
        let session: SharerSession
        do {
            try await relay.startShare(shareID, viewers: [alice, bob, carol], duration: .hours(1))
            session = try SharerSession(shareID: shareID, manifest: manifest, sealer: sealer, uplink: uplink,
                                        clock: clock, presenceTTL: config.presenceTTL,
                                        discretionaryBudget: Self.demoBudget, budgetRefill: .seconds(60))
        } catch {
            log(0, "Session refused: \(error)")
            return
        }
        log(0, "Share started · 3 viewers · expires in 60 min")

        // Alice and Carol keep the app open (WebSocket path). Bob is backgrounded (push path).
        for id in [alice, carol] {
            let stream = await relay.connect(id)
            consumers.append(Task { @MainActor [weak self] in
                for await event in stream { self?.handle(event, for: id) }
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
                await session.revoke(carol)
                revoked.insert(carol)
                log(second, "Carol revoked: sharer stops sealing for her; relay deletes her copy")
            }
            if second == 8 * 60 { await uplink.setDown(true); log(second, "Sharer loses network") }
            if second == 9 * 60 {
                await uplink.setDown(false)
                if case .published = await session.flushOutbox() { flushedAfterOutage = true }
                log(second, "Network back: latest-wins outbox flushed (\(flushedAfterOutage ? "1 batch" : "nothing held"))")
            }

            // Stationary devices stop producing fresh fixes; the heartbeat timer carries presence.
            let outcome: IngestOutcome
            if motion == .stationary {
                outcome = await session.tick(conditions: conditions)
            } else if let fix = LocationFix(latitude: lat, longitude: lon, accuracyMeters: 8, timestamp: clock.now()) {
                outcome = await session.ingest(fix, conditions: conditions)
            } else { outcome = .idle }
            if case .published(let reason, let seq, let receipt) = outcome, reason != .moved || seq % 8 == 1 {
                log(second, "#\(seq) \(reason.rawValue) → live \(receipt.deliveredLive.count), push-queued \(receipt.queuedForPush.count)")
            }
            if case .heldOffline(let seq) = outcome { log(second, "#\(seq) held offline (outbox keeps newest only)") }

            if second % 30 == 0 {
                for push in await relay.drainPushes() {
                    handle(.point(push.sealed), for: push.viewer)
                    if push.coalesced > 0 { log(second, "Push to \(names[push.viewer] ?? "?") replaced \(push.coalesced) older points") }
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
            sampleCiphertext = sample.ciphertext.prefix(18).map { String(format: "%02x", $0) }.joined()
        }
        // Let the stream consumers drain before the final render.
        for _ in 0..<20 { await Task.yield() }
        refreshViewers()
        log(Self.scenarioMinutes * 60, "Scenario complete")
        consumers.forEach { $0.cancel() }
    }

    private func handle(_ event: RelayEvent, for viewer: ViewerID) {
        switch event {
        case .point(let sealed):
            guard var inbox = inboxes[viewer] else { return }
            do {
                try inbox.receive(sealed)
                receivedCount[viewer, default: 0] += 1
            } catch {
                rejectedCount[viewer, default: 0] += 1
            }
            inboxes[viewer] = inbox
        case .revoked(let share), .ended(let share, _):
            inboxes[viewer]?.forget(share)
            revoked.insert(viewer)
        }
        refreshViewers()
    }

    private func refreshViewers() {
        let now = clock.now()
        viewers = [alice, bob, carol].map { id in
            let latest = inboxes[id]?.latest[shareID]?.payload
            let gone = revoked.contains(id)
            let fresh = Freshness.classify(lastSentAt: latest?.sentAt, now: now,
                                           heartbeat: config.presenceTTL.dividedBy(2), presenceTTL: config.presenceTTL,
                                           isViewerOffline: false, hasEnded: gone)
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
}
