#!/usr/bin/env python3
"""Mutation check: break each load-bearing guard on purpose and require the named test to FAIL.

A guard whose mutant still passes its test is a guard nothing is checking. This script applies one
mutant at a time, runs only the test that claims to cover it, restores the file, and exits non-zero
if any mutant survives. Run from the package root: python3 Scripts/mutation_check.py
"""
import pathlib
import subprocess
import sys

SRC = pathlib.Path("Sources/LiveLocation")

# (file, exact original text, mutant text, test filter that must fail)
MUTANTS = [
    ("LocationRelay.swift",
     "copy.sequence <= stored.sequence",
     "copy.sequence < stored.sequence",
     "RelayTests/testOutOfOrderDeliveryCannotMoveAPinBackwards"),
    ("LocationRelay.swift",
     "        latest[share]?[viewer] = nil\n        pending[viewer]?[share] = nil",
     "        pending[viewer]?[share] = nil",
     "RelayTests/testRevocationDeletesStoredCopyAndQueuedPushAndNotifies"),
    ("LocationRelay.swift",
     "Pending(sealed: copy, coalesced: Saturating.add(existing.coalesced, 1))",
     "Pending(sealed: existing.sealed, coalesced: Saturating.add(existing.coalesced, 1))",
     "RelayTests/testPushBudgetBurstsThenRefillsAndCoalescesToNewest"),
    ("LocationRelay.swift",
     "shares.filter { now >= $0.value.expiresAt }",
     "shares.filter { now > $0.value.expiresAt }",
     "RelayTests/testShareExpiresByTimeAndEverythingIsDeleted"),
    ("PublishPolicy.swift",
     "let heartbeat = max(Millis.seconds(1), presenceTTL.dividedBy(2))",
     "let heartbeat = max(Millis.seconds(1), presenceTTL)",
     "PublishPolicyTests/testHeartbeatIsStrictlyShorterThanPresenceTTLForEveryCondition"),
    ("PublishPolicy.swift",
     "        if elapsed >= cadence.heartbeatInterval { return .publish(.heartbeat) }\n",
     "",
     "PublishPolicyTests/testHeartbeatBeatsBothBudgetAndPoorAccuracy"),
    ("PublishPolicy.swift",
     "return discretionaryAllowed ? .publish(.moved) : .suppress(.budgetExhausted)",
     "return .publish(.moved)",
     "SharerSessionTests/testBudgetRunsDryButHeartbeatsContinue"),
    ("PublishPolicy.swift",
     ": lastRefill.adding(refillEvery.times(earned))",
     ": now",
     "PublishPolicyTests/testBucketBurstThenExactRefill"),
    ("SharerSession.swift",
     "        sealer.revoke(viewer)\n",
     "",
     "SharerSessionTests/testRevokeDuringAnInFlightUploadStillExcludesTheViewer"),
    ("SharerSession.swift",
     "guard manifest.capabilities.contains(.liveLocationSharing) else { throw SessionError.capabilityNotDeclared }",
     "",
     "SharerSessionTests/testSessionRefusesToExistWithoutTheDeclaredCapability"),
    ("FanoutCrypto.swift",
     "        var seq = sequence.bigEndian\n        withUnsafeBytes(of: &seq) { d.append(contentsOf: $0) }\n",
     "",
     "FanoutCryptoTests/testRelayCannotReaddressRenumberOrTamper"),
    ("FanoutCrypto.swift",
     "if let last = latest[sealed.shareID], sealed.sequence <= last.sequence {",
     "if let last = latest[sealed.shareID], sealed.sequence < last.sequence {",
     "FanoutCryptoTests/testInboxRejectsReplayAndOutOfOrderCopies"),
    ("Freshness.swift",
     "let liveWindow = Millis(Saturating.add(heartbeat.value, heartbeat.value / 2))",
     "let liveWindow = heartbeat",
     "FreshnessTests/testBoundaries"),
    ("AgeRatingGate.swift",
     "case (true, false): return [.undeclaredSharedLocation]",
     "case (true, false): return []",
     "AgeRatingGateTests/testAllFourCombinations"),
]


def run(filter_: str) -> bool:
    """True if the filtered tests pass. A hang counts as a failure (the mutant was detected)."""
    try:
        r = subprocess.run(["swift", "test", "--filter", filter_], capture_output=True, text=True, timeout=600)
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
