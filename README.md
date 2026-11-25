# LiveLocationKit

**"Design Find My", answered in Swift that compiles, runs and is tested.** It has an adaptive-rate publisher and per-viewer end-to-end encryption with a pinned sharer key. The relay keeps only the latest point, tracks presence with a TTL and enforces revocation even when it misbehaves. Background pushes run on a budget with coalescing, and an age-rating gate keeps the code consistent with the app's App Store Connect answer.

[![CI](https://github.com/rajatslakhina/live-location-share-kit/actions/workflows/ci.yml/badge.svg)](https://github.com/rajatslakhina/live-location-share-kit/actions/workflows/ci.yml)
![Swift 6](https://img.shields.io/badge/Swift-6-orange) ![iOS 17+ · macOS 14+](https://img.shields.io/badge/iOS%2017%2B%20%C2%B7%20macOS%2014%2B-blue) ![License: MIT](https://img.shields.io/badge/license-MIT-lightgrey)

<img src="https://raw.githubusercontent.com/rajatslakhina/live-location-share-demo-app/main/Demo/Screenshots/viewers.png" width="300" align="right" alt="Demo app on the iOS Simulator: Alice is live, Bob's background pin is six minutes old because of the push budget, Carol has been revoked; the relay stores only ciphertext.">

**Demo app:** [live-location-share-demo-app](https://github.com/rajatslakhina/live-location-share-demo-app) is a separate Xcode project that consumes this package as a remote Swift package pinned to a release. It runs a 12-minute scripted share (walk, then drive, then park) through every type below. It was run on the iOS Simulator, and the screenshot comes from that run. In it, 420 GPS fixes became 37 points. Alice watches live over a socket, Bob is backgrounded and limited by the push budget, and Carol is revoked halfway through.

## Why this matters now

On 16 Nov 2026 Apple added a **Shared Location** content descriptor to the App Store Connect age-rating questionnaire. It asks whether the app shares a user's real-world location with another person or group. Every app must answer by **12 Jan 2027**. In Brazil a "Yes" means an **A16** rating. That turns a classic system-design interview question, *design live location sharing*, into a product and compliance problem with a deadline.

The naive build streams GPS at 1 Hz to a server that fans plaintext out to every viewer, and it has five problems:

- It drains the battery.
- A parked phone keeps sending the same point.
- The server can read everyone's location.
- "Stop sharing with Carol" only works if the server behaves.
- Nothing links what the code does to what the age-rating form says.

This package is the version you could defend in a design review.

<br clear="right">

## The system

```
 Sharer device                                   Relay (server)                         Viewer devices
 ─────────────                                   ──────────────                         ──────────────
 CoreLocation fix ─▶ PublishPolicy ─▶ PublishGate        LocationRelay (actor)
   (motion, battery,   cadence:        first / moved /     • presence TTL            ┌─▶ foreground: points stream
    Low Power Mode)    interval,       heartbeat, or       • latest copy only        │   + control stream ─▶ PointInbox
                       distance,       suppress(reason)    • expiry + revocation ────┤                     (pinned sharer key,
                       heartbeat              │            • per-viewer push budget  └─▶ background: budgeted,   replay window)
                                              ▼              (oldest-waiting first)      coalescing push ─▶ PointInbox
                        TokenBucket (battery budget)              ▲
                                              ▼                   │  only routing headers are readable
                        PerViewerSealer ── one padded, sealed copy per viewer ─┘
                        X25519 → HKDF(both public keys) → ChaCha20-Poly1305
 CapabilityManifest ──▶ SharerSession refuses to start without .liveLocationSharing
                  └──▶ AgeRatingGate: manifest vs. the App Store Connect "Shared Location" answer (demo repo CI)
```

| Layer | Type | What it guarantees (each has a test) |
|---|---|---|
| Rate | `PublishPolicy`, `PublishGate` | Cadence follows motion, from 5 s / 50 m when driving down to 60 s / 100 m when parked (in practice heartbeat-only). Battery and Low Power Mode stretch it 2× or 4×. **The heartbeat is at most half the presence TTL** for every TTL the relay accepts, so even one lost heartbeat still lands inside the TTL. Out-of-order, too-soon, not-moved and inaccurate fixes are suppressed, each with a reason. |
| Battery | `TokenBucket` in `SharerSession` | A per-session budget of movement publishes. When it runs dry, the share drops to heartbeats only. **Heartbeats never spend it**, and a heartbeat that falls due on a poor fix re-sends the last good one. |
| Privacy | `PerViewerSealer`, `PerViewerOpener`, `PointInbox`, `FanoutAudit` | Each viewer's copy is sealed under its own key. The plaintext is padded to a fixed size, so length does not reveal the publish reason. The relay can read share, viewer and sequence, never coordinates. Viewers accept only the sharer key they pinned from the invitation, so **a relay that mints its own key cannot forge a point**. Copies that are re-addressed, renumbered, tampered with or replayed are rejected. |
| Revocation | `SharerSession.revoke`, `LocationRelay.revoke` | Enforced **on the sharer's device first**. Once `revoke` returns, nothing is sealed or uploaded for that key, even if an in-flight upload fails back into the offline outbox. The relay then deletes the stored copy and the queued push. If the relay call fails, it is retried by `flushOutbox`. |
| Server | `LocationRelay` (actor) | Stores only the latest copy per (share, viewer) and drops late copies by sequence. Tracks presence with a TTL. Ends shares by time or explicit stop, and viewers can be added mid-share. Enforces hard limits on share length, viewers per share and active shares. Housekeeping is indexed. |
| Delivery | `connect(_:)`, `drainPushes()` | Foreground viewers get a newest-wins point stream, and **a separate control stream**, so a burst of points can never evict "remove this pin". Background viewers get pushes under a per-viewer budget. The queue is served oldest-waiting first, and a delayed push carries the newest point, not a backlog. |
| Session | `SharerSession` (actor) | Survives app relaunch: the share key can be persisted, and sequences are epoch-based. It stops by itself when the relay reports the share gone, and `stop()` ends a share explicitly. |
| Viewer UI | `Freshness` | Live, delayed, stale, waiting and ended, plus "*you* are offline" as its own state. "The sharer went quiet" and "I have no network" never look the same. |
| Capacity | `FanoutLoadModel` | Publishes, sealed copies, socket connections and messages, pushes with and without budget, bytes, and storage for N active shares. |
| Compliance | `CapabilityManifest`, `AgeRatingGate` | One manifest drives the runtime (no manifest entry means no session). In the demo repo, CI runs the gate against the checked-in age-rating answer, including a control that must fail. |

## Design decisions and the alternatives I rejected

**Heartbeats instead of a stream when parked.** A stationary phone publishes only a heartbeat every TTL / 2: the last fix, with a fresh `sentAt`. Viewers see "here, as of 40 s ago", and the relay's presence stays alive. *Rejected:* a fixed 1 Hz stream. In the demo's 12-minute share the sharer sends 37 points, 6 of them heartbeats, where a 1 Hz publisher would send 720. *Also rejected:* scaling the heartbeat with battery the way the movement interval scales. That is the bug `testTheCheckCatchesAPolicyWhoseHeartbeatOutlivesTheTTL` feeds in, to prove the presence check is not vacuous. A heartbeat just under the TTL is rejected too: `testOneLostHeartbeatInARowStillNeverLetsPresenceLapse` drops every other heartbeat and fails that rule.

**One sealed copy per viewer, not one group key.** With a shared group key, revoking Carol means re-keying everyone, and until then Carol can read every copy the relay hands her. Here each copy is sealed under `HKDF(X25519(shareKey, viewerKey), salt: shareID, info: viewerID ‖ sharerKey ‖ viewerKey)`, and the AEAD tag binds (share, viewer, sequence). Revocation is just "stop sealing for that key". *Cost:* fan-out work and bytes grow with the number of viewers. That is why the load model counts copies, not publishes, and why viewers per share are capped. The group-key scheme is in the tests as a deliberately broken implementation, and `FanoutAudit` must flag it.

**The viewer pins the sharer's key from the invitation.** Without a pin, any relay that knows a viewer's public key could mint its own key and seal a valid-looking point, at sequence `UInt64.max`, which would lock real updates out for good. *Rejected:* trusting the key carried in each envelope, and signing every envelope with an Ed25519 identity key. Signing works too, but it needs an identity system the invitation pin does not. The forged-copy test includes a control showing the forgery *would* decrypt without the pin.

**Latest-wins everywhere.** The relay keeps one copy per (share, viewer), the push queue keeps one pending copy per (viewer, share), and the sharer's offline outbox keeps one batch. Location is a *state*, not an event log, so replaying history costs something and buys nothing. *Rejected:* a durable queue per viewer, which grows without bound for data that is worthless a minute later.

**A monotonic sequence assigned before the only `await`.** `SharerSession` decides, spends budget, assigns the sequence, seals and commits, all before uploading. Two overlapping calls therefore get increasing sequences in call order, and if their uploads land out of order the relay drops the older one. Sequences start at wall-clock ms × 2¹⁶, so a relaunched app is never mistaken for a replay. *Rejected:* server-assigned sequence numbers, which need a round trip before every publish and break offline buffering. *Also rejected:* ordering by fix timestamp, because CoreLocation re-delivers and heartbeats re-send old fixes.

**Budgeted, coalescing pushes, served oldest-first.** Background delivery is the expensive path: APNs, plus the on-device Live Activity update budget. The relay gives each background viewer a burst plus a sustained rate. A push that waits for budget is replaced by newer points, so it always carries the newest one, and the queue serves whichever share has waited longest, so one busy share cannot starve another. *Rejected:* silent background pushes for every point, which iOS throttles unpredictably and which the load model shows cost about 20× more. *Also rejected:* a per-viewer FIFO, which delivers stale points first. *Trade-off:* a background viewer's pin can be minutes old. The demo shows Bob in exactly that state, which is why `Freshness` shows age honestly instead of pretending everything is live.

**One manifest is the source of truth for both the runtime and App Store Connect.** `SharerSession.init` throws `capabilityNotDeclared` unless the manifest contains `.liveLocationSharing`. `AgeRatingGate.check` fails CI if that manifest and the exported "Shared Location" answer disagree. *Rejected:* a checklist item in the release process, which drifts the first time someone adds a share button.

**The SwiftUI scenario ships in the package (`LiveLocationUI`) rather than in the app.** The demo README quotes the scenario's numbers, so the scenario needs tests. A package test target (`LiveLocationUITests`) runs it headlessly and fails if 420, 37 or 6, or the Alice/Bob/Carol states, drift. The app stays a thin shell that owns only its config files, which is how a product team would consume a feature module.

## From actor to deployment

`LocationRelay` is the state machine one relay shard runs. Scaling it is mostly about partitioning and connection count, and the model gives the numbers. At **10 million active shares**, 3 viewers each, with the commuting-hour mix and 365-byte copies (the size the demo measures), the figures below come from `testTenMillionSharesFiguresQuotedInTheREADME`:

| Quantity | Value |
|---|---|
| Sharer publishes | 675,000 / s |
| Sealed copies accepted | 2,025,000 / s |
| Ingress | ≈ 739 MB / s |
| Open foreground connections | 9,000,000 |
| Background viewers | 21,000,000 |
| Pushes with the 5-minute budget | 252,000,000 / h (70,000 / s) |
| Latest-only storage | ≈ 11 GB |

How that maps onto infrastructure (assumptions, not measurements):

- **Partition by `ShareID`** with consistent hashing, so one share's presence, latest copies and expiry live on one shard. That is exactly the state this actor owns, so no cross-shard transactions are needed.
- **A connection tier in front of the shards.** At an assumed 100k WebSockets per gateway node, 9M connections need about 90 nodes. Gateways subscribe to the shards that hold their viewers' shares, which fans a copy out from shard to gateway to socket.
- **Presence and latest copies in memory** (about 11 GB fleet-wide), with TTL expiry. Losing a shard loses at most one heartbeat interval of state, because sharers re-publish within TTL / 2.
- **APNs at 70k/s** is within what a pool of HTTP/2 connections handles. Without the budget it would be about 1.4M/s, about 20× more, which is why the budget lives on the server and not on the client.

## Verification

- `swift build -Xswiftc -warnings-as-errors` from a clean `.build`, then `swift test` on macOS: **66 tests, 0 failures**, of which 65 are library tests and 1 is the demo-scenario test.
- `xcodebuild build` of both library targets for the iOS Simulator SDK, with warnings as errors.
- `Scripts/mutation_check.py` plants 21 deliberate bugs, one at a time. Examples include accepting an equal sequence as new, leaving the sharer-key pin unchecked, removing the revoke-before-await line, re-adding revoked viewers to the outbox, doubling the TTL/2 heartbeat, dropping the plaintext padding, and serving pushes by name instead of age. Each mutant must compile, and its named test must **fail**. Each named test must also pass when no mutant is applied.
- CI runs all three on pushes to `main`, on tags and on pull requests. See the [Actions tab](https://github.com/rajatslakhina/live-location-share-kit/actions).
- The demo app was built against this package's release tag (resolved from GitHub), installed and launched on an iOS Simulator, and screenshotted, as described in the [demo repo](https://github.com/rajatslakhina/live-location-share-demo-app#verification--exactly-what-happened).

## Honest limits

- **The relay is an in-process actor, not a deployed server.** It is the state machine a server shard would run. There is no HTTP or WebSocket transport, no persistence and no horizontal scaling here; the section above is a design, not an implementation. `RelayUplink` is the seam a network client would implement.
- **No relay authentication.** Anyone who can reach the actor can `connect` as any viewer ID, or keep presence alive by publishing. Points stay unreadable and unforgeable, but presence and routing are not access-controlled. A real deployment needs authenticated viewer and sharer sessions.
- **Key distribution is out of scope.** The sharer's key travels with the invitation and viewer keys come through the account system, both assumed to be authentic. In production you would use key transparency or safety-number verification.
- **The relay still sees metadata.** It sees who shares with whom, when, and how often. Publish cadence reveals coarse motion and battery state (5, 15 or 60 s intervals; 2× or 4× stretch), even though plaintext padding hides the publish reason.
- **Forward secrecy is limited.** There is one X25519 key per share. Compromise of that key exposes that share's copies, and compromise of a viewer's long-term key exposes every share ever sent to that viewer. Rotating per epoch is a straightforward extension.
- **Viewer replay state lives in memory.** `PointInbox` rejects replays only within one app process. An app that must reject replays across its own relaunches should persist the last sequence per share.
- **Push budgets reset with a viewer's last share.** A viewer left on no share loses their budget entry, which keeps memory bounded. Added to a new share later, they start with a fresh burst.
- **No real APNs or ActivityKit.** `drainPushes()` returns what a sender would hand to APNs. Apple's on-device Live Activity budgets are not modelled.
- **`LiveUpdatesSource`, the `CLLocationUpdate.liveUpdates` adapter, compiles but is not exercised** by the tests or the demo, which drives a scripted route. Authorization prompts, background modes and a significant-change fallback are the app's job and are not implemented.
- **The load model is an estimate.** It assumes full battery and that moving sharers clear the distance threshold every interval, which overestimates load (the right direction for capacity planning). It counts messages and bytes, not CPU.
- **The age-rating gate checks one descriptor** against a JSON export kept in the repo. It does not call the App Store Connect API.

## Use it

```swift
.package(url: "https://github.com/rajatslakhina/live-location-share-kit.git", from: "1.0.1")
```

```swift
import LiveLocation

// Relay side (in-process here; a server shard in production).
let relay = LocationRelay(configuration: RelayConfiguration(presenceTTL: .seconds(120)))
let share = ShareID(UUID().uuidString)                    // random: the relay can read share IDs
try await relay.startShare(share, viewers: [aliceID], duration: .hours(1))

// Sharer side. `aliceKey` is Alice's public key (Data) from your account system;
// `sealer.sharePublicKey` goes to Alice inside the invitation, and she pins it.
var sealer = PerViewerSealer(shareID: share)              // persist sealer.privateKeyRaw in the Keychain
try sealer.add(aliceID, publicKey: aliceKey)
let manifest = try CapabilityManifest.decode(Data(contentsOf: manifestURL))   // your bundled capabilities.json
let session = try SharerSession(shareID: share, manifest: manifest, sealer: sealer, uplink: relay,
                                clock: SystemClock(), presenceTTL: relay.configuration.presenceTTL)

// Heartbeats keep presence alive when CoreLocation goes quiet (e.g. while parked).
let heartbeat = Task {
    while !Task.isCancelled {
        try await Task.sleep(for: .seconds(5))
        _ = await session.tick(conditions: DeviceConditions(batteryLevel: 0.8, motion: .stationary))
    }
}
for await fix in LiveUpdatesSource.fixes(for: .walking) {
    if await session.ingest(fix, conditions: DeviceConditions(batteryLevel: 0.8, motion: .walking)) == .ended { break }
}
heartbeat.cancel()

// Viewer side.
var inbox = PointInbox(opener: PerViewerOpener(keys: aliceKeys))
inbox.trust(share, sharerPublicKey: invitation.sharePublicKey)
let connection = await relay.connect(aliceID)
for await copy in connection.points { if let point = try? inbox.receive(copy) { /* move the pin */ } }
```

Products: `LiveLocation` (the core, no UI) and `LiveLocationUI` (the SwiftUI scenario the demo app shows). iOS 17+ and macOS 14+, Swift 6 language mode.

MIT licensed.
