# Changelog

All tags were published on 25 Nov 2026, and each was checked by an independent review before the next. Use the latest.

## 2.1.1
- **Relay reconciliation.** Revokes and adds for one viewer carry a generation number, so a slow reply to an older call can no longer clear a newer pending operation. Instead, the session re-sends the current intent.
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
Initial release. Superseded: use 2.1.1 or later.
