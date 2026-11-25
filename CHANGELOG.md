# Changelog

All tags were published on 25 Nov 2026. Six independent review rounds drove the fixes. Use the latest.

## 2.1.2
- **Single-flight relay calls per viewer.** These replace the 2.1.1 generation-and-resend logic, which could ping-pong forever when two calls for one viewer overlapped (for example `revoke` plus the flush timer). At most one relay call per viewer is now in flight. When it returns, the session sends the latest intent, and stops once that intent has been acknowledged. A stale refusal no longer removes a re-added viewer.
- **Load model.** Overflowing inputs now clamp high instead of reading as zero load.
- **Demo.** The Sharer card shows the split of 37 points into 32 from fixes and 5 parked heartbeats. Only a manifest refusal is blamed on the manifest.

## 2.1.1
- **Relay reconciliation (superseded in 2.1.2).** Per-viewer generation numbers re-sent the current intent after a stale reply.
- **Permanent relay refusals.** `tooManyViewers` and `unknownShare` responses to `addViewer` are treated as final and are not retried.
- **`flushOutbox` after `stop()`.** It returns `.ended` if `stop()` ran during its upload, whether that upload succeeded or failed.
- **Demo.** A refused session is shown as such instead of "Preparing…".

## 2.1.0
- **Pending relay adds.** These are retried by `flushOutbox`, symmetric with revocations.
- **`addViewer`.** Returns whether the relay acknowledged, and throws `SessionError.shareEnded` after `stop()`.
- **Clock-driven sequences.** By default a junk copy blocks a share for at most 5 minutes plus clock skew.
- **Connections.** Capped per viewer, and closed when a viewer leaves their last share.
- **Push budgets.** They survive a revoke followed by a re-add until they fully refill.
- **First point.** The first published point must be accurate.
- **Source-breaking for exhaustive switches:** new cases `SessionError.shareEnded`, `RelayError.notAViewer` and `RelayError.tooManyConnections`.

## 2.0.0
Re-releases the source-breaking fixes first tagged as 1.0.1–1.0.5 under a major version:
- **Relay API.** `connect` throws and returns `RelayConnection { points, control }`. `RelayUplink` gains `presenceTTL`, `addViewer` and `stop`.
- **Session API.** `SharerSession.init` loses `presenceTTL:`. `addViewer` and `stop()` become `async`.
- **New cases.** `IngestOutcome` gains `.rejected` and `.ended`. `Freshness` gains `.behind`.
- **Trust.** `PointInbox` and `PerViewerOpener` require `trust(_:sharerPublicKey:)` before opening.
- **Errors.** `FanoutCryptoError` gains `.untrustedSharerKey` and `.badViewerKey`.
- **Future sequences.** The relay rejects copies whose sequence is far in the future (`futureSequence`).
- **Retries.** A failed `stop()` is retried.
- **Decoding.** Validated decoding for `LocationFix` and `Millis`.

## 1.0.1 – 1.0.5 (superseded by 2.0.0)
- **1.0.1: three serious fixes.**
  - Sharer-key pinning, which closes relay forgery.
  - A copy sealed before `revoke` can no longer reach the revoked viewer through a failed upload.
  - Epoch-based sequences and restorable keys, which fix relaunch lock-out.
- **1.0.1: other changes.** A control stream, oldest-first pushes, padding, `addViewer` on the relay, and the scenario test target.
- **1.0.2–1.0.5.** Demo UI polish, plus removal of a redundant outbox filter that was masking a mutant.

## 1.0.0
Initial release. Superseded: use 2.1.2 or later.
