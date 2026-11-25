#!/usr/bin/env python3
"""Mutation check: break each load-bearing guard on purpose and require the named test to FAIL.

A guard whose mutant still passes its test is a guard nothing is checking. This script applies one
mutant at a time, runs only the test that claims to cover it, restores the file, and exits non-zero
if any mutant survives. Run from the package root: python3 Scripts/mutation_check.py
"""
import pathlib
import functools
print = functools.partial(print, flush=True)  # noqa: A001 — stream progress in CI logs
import subprocess
import sys

import shutil
import tempfile

import atexit

ROOT = pathlib.Path(tempfile.mkdtemp(prefix="llk-mutants-"))
atexit.register(shutil.rmtree, ROOT, ignore_errors=True)
# Work on a throwaway copy so an interrupted run can never leave a mutant in the real working tree.
# .build is not copied: its build database records absolute paths, so a copied one forces full rebuilds.
shutil.copytree(".", ROOT, dirs_exist_ok=True, symlinks=True, ignore=shutil.ignore_patterns(".git", ".build"))
SRC = ROOT / "Sources/LiveLocation"

# (file, exact original text, mutant text, test filter that must fail)
MUTANTS = [
    ('SharerSession.swift',
     '        for viewer in desiredOnRelay.keys.sorted() { _ = try? await reconcile(viewer) }\n',
     '',
     'SharerSessionTests/testAnOfflineAddOfANewViewerIsRetriedByFlush'),
    ('LocationRelay.swift',
     'copy.sequence <= stored.sequence',
     'copy.sequence < stored.sequence',
     'RelayTests/testOutOfOrderDeliveryCannotMoveAPinBackwards'),
    ('LocationRelay.swift',
     '        latest[share]?[viewer] = nil\n        pending[viewer]?[share] = nil',
     '        pending[viewer]?[share] = nil',
     'RelayTests/testRevocationDeletesStoredCopyAndQueuedPushAndNotifies'),
    ('LocationRelay.swift',
     '= Pending(sealed: copy, coalesced: Saturating.add(existing.coalesced, 1),',
     '= Pending(sealed: existing.sealed, coalesced: Saturating.add(existing.coalesced, 1),',
     'RelayTests/testPushBudgetBurstsThenRefillsAndCoalescesToNewest'),
    ('LocationRelay.swift',
     'shares.filter { now >= $0.value.expiresAt }',
     'shares.filter { now > $0.value.expiresAt }',
     'RelayTests/testShareExpiresByTimeAndEverythingIsDeleted'),
    ('PublishPolicy.swift',
     'let heartbeat = max(minimumPresenceTTL, presenceTTL).dividedBy(2)',
     'let heartbeat = max(minimumPresenceTTL, presenceTTL).dividedBy(2).times(2)',
     'PublishPolicyTests/testHeartbeatIsAtMostHalfThePresenceTTLForEveryCondition'),
    ('PublishPolicy.swift',
     '        if elapsed >= cadence.heartbeatInterval { return .publish(.heartbeat) }\n',
     '',
     'PublishPolicyTests/testHeartbeatBeatsBothBudgetAndPoorAccuracy'),
    ('PublishPolicy.swift',
     'return discretionaryAllowed ? .publish(.moved) : .suppress(.budgetExhausted)',
     'return .publish(.moved)',
     'SharerSessionTests/testBudgetRunsDryButHeartbeatsContinue'),
    ('PublishPolicy.swift',
     ': lastRefill.adding(refillEvery.times(earned))',
     ': now',
     'PublishPolicyTests/testBucketBurstThenExactRefill'),
    ('SharerSession.swift',
     '    public func revoke(_ viewer: ViewerID) async -> Bool {\n        sealer.revoke(viewer)\n',
     '    public func revoke(_ viewer: ViewerID) async -> Bool {\n',
     'SharerSessionTests/testRevokeDuringAnInFlightUploadStillExcludesTheViewer'),
    ('SharerSession.swift',
     '                outbox = copies.filter { current.contains($0.viewerID) }',
     '                outbox = copies',
     'SharerSessionTests/testRevokeDuringAFailingUploadNeverLeaksToTheRevokedViewer'),
    ('SharerSession.swift',
     'if receipt.shareIsGone { endLocally(); return .ended }\n            return receipt.accepted ? .published(payload.reason',
     'return receipt.accepted ? .published(payload.reason',
     'SharerSessionTests/testSessionStopsWhenTheRelayHasForgottenTheShare'),
    ('SharerSession.swift',
     '            toSend = good\n',
     '',
     'SharerSessionTests/testAHeartbeatOnAPoorFixResendsTheLastGoodFix'),
    ('PublishPolicy.swift',
     '        if fix.accuracyMeters > maxAccuracyMeters { return .suppress(.inaccurate) }\n        if elapsed < cadence.minInterval { return .suppress(.tooSoon) }',
     '        if elapsed < cadence.minInterval { return .suppress(.tooSoon) }\n        if fix.accuracyMeters > maxAccuracyMeters { return .suppress(.inaccurate) }',
     'PublishPolicyTests/testPoorAccuracyIsJudgedBeforeTimingAndMovement'),
    ('FanoutCrypto.swift',
     'guard let pinned = trustedSharers[sealed.shareID], pinned == sealed.sharerPublicKey',
     'guard let pinned = Optional(sealed.sharerPublicKey)',
     'FanoutCryptoTests/testRelayForgedKeyIsRejectedEvenWithAValidTag'),
    ('FanoutCrypto.swift',
     '        out.append(Data(repeating: 0x20, count: buckets * bucket - json.count))\n',
     '',
     'FanoutCryptoTests/testCiphertextLengthDoesNotRevealThePublishReason'),
    ('LocationRelay.swift',
     'let order = queue.sorted { ($0.value.waitingSince, $0.key.raw) < ($1.value.waitingSince, $1.key.raw) }',
     'let order = queue.sorted { $0.key.raw < $1.key.raw }',
     'RelayTests/testPushQueueIsServedOldestFirstSoABusyShareCannotStarveAQuietOne'),
    ('SharerSession.swift',
     'guard manifest.capabilities.contains(.liveLocationSharing) else { throw SessionError.capabilityNotDeclared }',
     '',
     'SharerSessionTests/testSessionRefusesToExistWithoutTheDeclaredCapability'),
    ('FanoutCrypto.swift',
     '        var seq = sequence.bigEndian\n        withUnsafeBytes(of: &seq) { d.append(contentsOf: $0) }\n',
     '',
     'FanoutCryptoTests/testRelayCannotReaddressRenumberOrTamper'),
    ('FanoutCrypto.swift',
     'if let last = latest[sealed.shareID], sealed.sequence <= last.sequence {',
     'if let last = latest[sealed.shareID], sealed.sequence < last.sequence {',
     'FanoutCryptoTests/testInboxRejectsReplayAndOutOfOrderCopies'),
    ('Freshness.swift',
     'let liveWindow = Millis(Saturating.add(heartbeat.value, heartbeat.value / 2))',
     'let liveWindow = heartbeat',
     'FreshnessTests/testBoundaries'),
    ('LocationRelay.swift',
     'guard copy.sequence <= SharerSession.epochSequence(now.adding(Self.maxSequenceLead)) else {',
     'guard true else {',
     'RelayTests/testAJunkCopyAtUInt64MaxIsRejected'),
    ('SharerSession.swift',
     '        if pendingRelayStop, await stopAtRelay() { pendingRelayStop = false }\n',
     '',
     'SharerSessionTests/testAStopThatFailsOfflineIsRetriedWithPendingRevocations'),
    ('Freshness.swift',
     '        if sharerOnline { return .behind(age: age) }\n',
     '',
     'FreshnessTests/testAnOldCopyFromAnOnlineSharerIsBehindNotStale'),
    ('SharerSession.swift',
     'let seq = clockDrivenSequence ? max(nextSequence, Self.epochSequence(payload.sentAt)) : nextSequence',
     'let seq = nextSequence',
     'SharerSessionTests/testClockDrivenSequencesOutrunAJunkCopyOnceTheClockPassesIt'),
    ('PublishPolicy.swift',
     'return fix.accuracyMeters > maxAccuracyMeters ? .suppress(.inaccurate) : .publish(.first)',
     'return .publish(.first)',
     'PublishPolicyTests/testAPoorFirstFixIsNeverPublished'),
    ('LocationRelay.swift',
     '            if bucket.tokens == bucket.capacity { pushBudgets[viewer] = nil }',
     '            pushBudgets[viewer] = nil',
     'RelayTests/testRevokeAndReAddCannotResetAPushBudget'),
    ('LocationRelay.swift',
     '                for c in conns.values { c.points.finish(); c.control.finish() }',
     '                _ = conns',
     'RelayTests/testAViewerLeftOnNoShareIsDisconnected'),
    ('SharerSession.swift',
     '            guard !isEnded else { return .ended }                            // never refill the outbox after stop()\n',
     '',
     'SharerSessionTests/testStopDuringAFailingUploadNeverRefillsTheOutbox'),
    ('LocationRelay.swift',
     'guard viewerShares[viewer]?.isEmpty == false else { throw RelayError.notAViewer }',
     'guard true else { throw RelayError.notAViewer }',
     'RelayTests/testConnectRefusesStrangersAndCapsConnectionsPerViewer'),
    ('SharerSession.swift',
     '        } catch {\n            guard !isEnded else { return .ended }\n            // Nothing held',
     '        } catch {\n            // Nothing held',
     'SharerSessionTests/testFlushReturnsEndedWhenStopRunsDuringAFailedUpload'),
    ('SharerSession.swift',
     '            guard !isEnded else { return .ended }                            // stop() ran during the upload\n            if receipt.shareIsGone',
     '            if receipt.shareIsGone',
     'SharerSessionTests/testFlushReturnsEndedWhenStopRunsDuringASuccessfulUpload'),
    ('AgeRatingGate.swift',
     'case (true, false): return [.undeclaredSharedLocation]',
     'case (true, false): return []',
     'AgeRatingGateTests/testAllFourCombinations'),
    ('SharerSession.swift',
     '        guard !reconciling.contains(viewer) else { return false }   // the in-flight call will pick up the intent\n',
     '',
     'SharerSessionTests/testRelayCallsForOneViewerAreSingleFlight'),
    ('SharerSession.swift',
     '            if desiredOnRelay[viewer]?.onShare == sent.onShare { desiredOnRelay[viewer] = nil; return true }',
     '            desiredOnRelay[viewer] = nil; return true',
     'SharerSessionTests/testAReAddDuringASuccessfulRevokeEndsWithTheViewerOnTheRelay'),
    ('SharerSession.swift',
     '                guard desiredOnRelay[viewer]?.epoch == sent.epoch else { continue }',
     '                guard desiredOnRelay[viewer]?.onShare == true else { continue }',
     'SharerSessionTests/testAStaleRefusalCannotDropAViewerReAddedAfterASlotFreedUp'),
    ('SharerSession.swift',
     '                refusedAdds[viewer] = refusal\n',
     '',
     'SharerSessionTests/testARefusalMetByAFlushRetryIsReported'),
    ('SharerSession.swift',
     '        if isEnded { throw SessionError.shareEnded }                // stop() ran while the add was in flight\n',
     '',
     'SharerSessionTests/testAnAddOverlappingStopThrowsShareEnded'),
    ('SharerSession.swift',
     '            } catch RelayError.unknownShare where !sent.onShare {\n',
     '            } catch RelayError.unknownShare where false {\n',
     'SharerSessionTests/testRevokeAndStopTreatAnUnknownShareAsDone'),
    ('LocationRelay.swift',
     '            if bucket.tokens == bucket.capacity { pushBudgets[viewer] = nil }',
     '            _ = bucket.tokens',
     'RelayTests/testABudgetOfAViewerOnNoShareIsKeptUntilFullThenDropped'),
    ('SharerSession.swift',
     '                sealer.revoke(viewer)\n                outbox.removeAll { $0.viewerID == viewer }\n',
     '',
     'SharerSessionTests/testARelayRefusalOfAnAddIsPermanentNotRetried'),
    ('SharerSession.swift',
     '        _ = try? await reconcile(viewer)\n        return desiredOnRelay[viewer] == nil',
     '        return (try? await reconcile(viewer)) ?? false',
     'SharerSessionTests/testRevokeReportsDoneWhenALaterAddWasFinallyRefused'),
    ('SharerSession.swift',
     '        return acknowledged && sealer.recipients.contains(viewer)',
     '        return acknowledged',
     'SharerSessionTests/testAddViewerReportsFalseWhenARevokeWonWhileTheAddWasInFlight'),
    ('SharerSession.swift',
     '            } else if outbox.isEmpty {\n                return .idle                                     // a newer batch was already uploaded\n            }',
     '            }',
     'SharerSessionTests/testAFailedOlderUploadIsIdleWhenANewerBatchAlreadyUploaded'),
    ('SharerSession.swift',
     'return outbox.isEmpty ? .idle : .heldOffline(sequence: seq)',
     'return .heldOffline(sequence: seq)',
     'SharerSessionTests/testAFailedFlushIsIdleWhenANewerBatchUploadedMeanwhile'),
]


def compiles() -> bool:
    """A mutant that does not compile proves nothing about the tests; treat it as a setup error."""
    r = subprocess.run(["swift", "build", "--build-tests"], capture_output=True, text=True, cwd=ROOT)
    return r.returncode == 0


def run(filter_: str) -> bool:
    """True if the filtered tests pass. A hang counts as a failure (the mutant was detected)."""
    try:
        r = subprocess.run(["swift", "test", "--filter", filter_], capture_output=True, text=True, timeout=600, cwd=ROOT)
    except subprocess.TimeoutExpired:
        return False
    return r.returncode == 0


def main() -> int:
    survivors = []
    for name, original, mutant, test in MUTANTS:
        path = SRC / name
        text = path.read_text()
        if text.count(original) != 1:
            print(f"SETUP ERROR: {name}: original text found {text.count(original)} times: {original!r}")
            return 2
        path.write_text(text.replace(original, mutant))
        try:
            if not compiles():
                print(f"SETUP ERROR: {name}: mutant does not compile: {mutant!r}")
                return 2
            passed = run(test)
        finally:
            path.write_text(text)
        verdict = "SURVIVED (bad)" if passed else "killed"
        print(f"{verdict:15} {name}: {original.strip()[:70]!r} -> {test}")
        if passed:
            survivors.append((name, test))
    # Sanity: with no mutant applied, every named test must pass, or "killed" meant nothing.
    for test in sorted({t for *_, t in MUTANTS}):
        if not run(test):
            print(f"BASELINE FAILURE: {test} fails without any mutant")
            return 3
    print(f"{len(MUTANTS) - len(survivors)}/{len(MUTANTS)} mutants killed; baseline green")
    return 1 if survivors else 0


if __name__ == "__main__":
    sys.exit(main())
