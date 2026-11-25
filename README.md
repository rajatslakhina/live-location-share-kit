# LiveLocationKit

**"Design Find My" — answered in Swift that compiles, runs and is tested.** An adaptive-rate publisher, per-viewer end-to-end encryption, a relay that keeps only the latest point, presence with a TTL, revocation that works even if the server misbehaves, a push budget with coalescing, and an age-rating gate that ties the code to its App Store Connect answer.

[![CI](https://github.com/rajatslakhina/live-location-share-kit/actions/workflows/ci.yml/badge.svg)](https://github.com/rajatslakhina/live-location-share-kit/actions/workflows/ci.yml)
![Swift 6](https://img.shields.io/badge/Swift-6-orange) ![iOS 17+ · macOS 14+](https://img.shields.io/badge/iOS%2017%2B%20%C2%B7%20macOS%2014%2B-blue) ![License: MIT](https://img.shields.io/badge/license-MIT-lightgrey)

Demo app: (added after the companion repo is pushed — see below)

---

## Why this matters now

On 16 Nov 2026 Apple added a **Shared Location** content descriptor to the App Store Connect age-rating questionnaire: does the app share a user's real-world location with another person or group? Every app has to answer by **12 Jan 2027**. That turns the classic system-design interview question — *design live location sharing* — into a product and compliance problem with a deadline.

The naive build is a 1 Hz GPS stream to a server that fans plaintext out to everyone. It drains the battery, sends a stream of identical points from a parked phone, lets the server read everyone's location, makes "stop sharing with Carol" depend on the server behaving, and has no link between what the code does and what the age-rating form says. This package is the version you would defend in a design review.

## The system

```
 Sharer device                                   Relay (server)                         Viewer devices
 ─────────────                                   ──────────────                         ──────────────
 CoreLocation fix ─▶ PublishPolicy ─▶ PublishGate        LocationRelay (actor)
   (motion, battery,   cadence:        first / moved /     • presence TTL            ┌─▶ foreground: AsyncStream
    Low Power Mode)    interval,       heartbeat, or       • latest copy only        │   ("WebSocket")  ─▶ PointInbox
                       distance,       suppress(reason)    • expiry + revocation ────┤                     (decrypt,
                       heartbeat              │            • per-viewer push budget  └─▶ background: budgeted, coalesced
                                              ▼              + coalescing                 push ("Live Activity") ─▶ PointInbox
                        TokenBucket (battery budget)              ▲
                                              ▼                   │  only routing headers are readable
                        PerViewerSealer ── one sealed copy per viewer ─┘
                        X25519 → HKDF → ChaCha20-Poly1305
 CapabilityManifest ──▶ SharerSession refuses to start without .liveLocationSharing
                  └──▶ AgeRatingGate (CI): manifest vs. the App Store Connect "Shared Location" answer
```

| Layer | Type | What it guarantees (each has a test) |
|---|---|---|
| Rate | `PublishPolicy`, `PublishGate` | Cadence follows motion (5 s / 50 m driving, down to 60 s / 100 m parked — in practice heartbeat-only) and stretches 2× / 4× with battery and Low Power Mode. **The heartbeat is always strictly shorter than the presence TTL**, so an online sharer never reads as "away". Out-of-order, too-soon, not-moved and inaccurate fixes are suppressed with a reason. |
| Battery | `TokenBucket` in `SharerSession` | A per-session budget of movement publishes. When it runs dry the share degrades to heartbeats; **heartbeats never spend it**. |
| Privacy | `PerViewerSealer`, `PerViewerOpener`, `PointInbox`, `FanoutAudit` | Each viewer's copy is sealed under its own key. The relay can read share, viewer and sequence — never coordinates. A copy re-addressed or renumbered by the relay fails authentication; a replayed or older copy cannot move a pin backwards. |
| Revocation | `SharerSession.revoke`, `LocationRelay.revoke` | Enforced **on the sharer's device first**: once `revoke` returns, nothing is sealed for that key, even if an upload was in flight or the relay keeps forwarding. The relay then deletes the stored copy and queued push. |
| Server | `LocationRelay` (actor) | Stores only the latest copy per (share, viewer); drops late copies by sequence; presence with a TTL; time expiry and explicit stop; hard limits on share length, viewers per share and active shares. |
| Delivery | `connect(_:)`, `drainPushes()` | Foreground viewers get a stream with a bounded buffer (a slow consumer drops its oldest events, never blocks the relay). Background viewers get pushes under a per-viewer budget; a delayed push carries the newest point, not a backlog. |
| Viewer UI | `Freshness` | Live / delayed / stale / waiting / ended, and "*you* are offline" as its own state — "the sharer went quiet" and "I have no network" never render the same. |
| Capacity | `FanoutLoadModel` | Publishes, sealed copies, socket messages, pushes (with and without budget), bytes and storage per N active shares. |
| Compliance | `CapabilityManifest`, `AgeRatingGate` | One checked-in manifest drives both the runtime (no manifest entry, no session) and a CI check against the exported age-rating answer. |

## Design decisions and the alternatives I rejected

**Heartbeats instead of a stream when parked.** A stationary phone publishes only a heartbeat — the last fix with a fresh `sentAt` — every TTL / 2. Viewers see "here, as of 40 s ago" and the relay's presence stays alive. *Rejected:* a fixed 1 Hz stream (the scripted demo sends far fewer points than its 720 GPS fixes — see the demo's Sharer tab); and scaling the heartbeat with battery like the movement interval — that is the bug `testTheCheckCatchesAPolicyWhoseHeartbeatOutlivesTheTTL` feeds in to prove the presence check is not vacuous.

**One sealed copy per viewer, not one group key.** With a shared group key, "revoke Carol" means re-keying everyone, and until then Carol can read every copy the relay hands her. Here each copy is sealed under `HKDF(X25519(shareKey, viewerKey), salt: shareID, info: viewerID)` with the AEAD tag binding (share, viewer, sequence), so revocation is simply "stop sealing for that key". *Cost:* fan-out work and bytes grow with the number of viewers (the load model counts copies, not publishes, for this reason), which is why viewers per share are capped. The group-key scheme is in the tests as a deliberately broken implementation, and `FanoutAudit` must flag it.

**Latest-wins everywhere.** The relay keeps one copy per (share, viewer); the push queue keeps one pending copy per (viewer, share); the sharer's offline outbox keeps one batch. Location is a *state*, not an event log, so replaying history is cost with no benefit. *Rejected:* a durable queue per viewer — unbounded growth for data that is worthless a minute later.

**Monotonic sequence assigned before the only `await`.** `SharerSession` decides, spends budget, commits the gate, assigns the sequence and seals — all before uploading. Two overlapping calls therefore get increasing sequences in call order, and if their uploads land out of order the relay drops the older one. The test parks an upload mid-flight, runs a second publish through the actor's reentrancy window, and checks the late one loses.

**Budgeted, coalescing pushes.** Background delivery is the expensive path (APNs, and on-device Live Activity update budgets). The relay gives each background viewer a burst plus a sustained rate; a push that waits for budget is replaced by newer points, so it always carries the newest one. *Trade-off:* a background viewer's pin can be minutes old — the demo shows Bob in that state — which is why `Freshness` renders age honestly instead of pretending everything is live.

**The manifest is the source of truth for both runtime and App Store Connect.** `SharerSession.init` throws `capabilityNotDeclared` unless the manifest contains `.liveLocationSharing`, and `AgeRatingGate.check` fails CI if that manifest and the exported "Shared Location" answer disagree. *Rejected:* a checklist item in the release process — it drifts the first time someone adds a share button.

## Verification

- `swift build -Xswiftc -warnings-as-errors` and `swift test` on macOS: **48 tests, 0 failures** (clean build from an empty `.build`).
- `xcodebuild build` of both library targets for the iOS Simulator SDK, warnings as errors.
- `Scripts/mutation_check.py`: 14 deliberate bugs (dropping the stale-sequence check, the revoke-before-await line, the TTL/2 heartbeat, push coalescing, the sequence in the AEAD associated data, …) — each must make its named test **fail**, and every named test must pass without a mutant.
- All three run in CI on every push: see the [Actions tab](https://github.com/rajatslakhina/live-location-share-kit/actions).
- Demo app: (verification added after the companion repo is pushed)

## Honest limits

- **The relay is an in-process actor, not a deployed server.** It is the state machine a server would run; there is no HTTP/WebSocket transport, persistence, horizontal scaling or auth here. `RelayUplink` is the seam a network client would implement.
- **No real APNs or ActivityKit.** `drainPushes()` returns what a sender would hand to APNs; Live Activity budgets on device are Apple's and are not modelled.
- **`LiveUpdatesSource` (the `CLLocationUpdate.liveUpdates` adapter) compiles but is not exercised** by tests or the demo, which drives a scripted route. Authorization prompts, background modes and a significant-change fallback are the app's job and are not implemented.
- **Key distribution is out of scope.** Viewer public keys are assumed to arrive authentically (in production: via the account system, with key transparency or safety-number verification). The relay can still see *who shares with whom and when* — metadata, not coordinates.
- **No forward secrecy within a share.** One X25519 key per share; compromise of that key exposes that share's copies. Rotating per epoch is a straightforward extension.
- **The load model is an estimate**, at full battery, assuming moving sharers clear the distance threshold every interval (an over-estimate, the right direction for capacity planning). It counts messages and bytes, not CPU.
- **The age-rating gate checks one descriptor** against a JSON export you keep in the repo; it does not call the App Store Connect API.

## Use it

```swift
.package(url: "https://github.com/rajatslakhina/live-location-share-kit.git", from: "1.0.0")
```

```swift
import LiveLocation

let relay = LocationRelay(configuration: RelayConfiguration(presenceTTL: .seconds(120)))
try await relay.startShare(ShareID("s1"), viewers: [alice.viewerID], duration: .hours(1))

var sealer = PerViewerSealer(shareID: ShareID("s1"))
try sealer.add(alice.viewerID, publicKey: alice.publicKey)
let session = try SharerSession(shareID: ShareID("s1"), manifest: manifest, sealer: sealer,
                                uplink: relay, clock: SystemClock(), presenceTTL: .seconds(120))

for await fix in LiveUpdatesSource.fixes(for: .walking) {
    _ = await session.ingest(fix, conditions: DeviceConditions(batteryLevel: 0.8, motion: .walking))
}
```

Products: `LiveLocation` (core, no UI) and `LiveLocationUI` (the SwiftUI scenario the demo app shows). iOS 17+ / macOS 14+, Swift 6 language mode.

MIT licensed.
