import XCTest
import CryptoKit
@testable import LiveLocation

/// A deliberately broken scheme: one symmetric "group key" shared by every viewer, and associated data
/// that binds the share and sequence but not the viewer. It is what a team ships when "encrypt it" is the
/// whole requirement. The audit must flag it; if it ever stopped flagging it, the audit would be vacuous.
struct GroupKeySealer: FanoutSealing {
    let shareID: ShareID
    var recipients: [ViewerID]
    let key: SymmetricKey

    func sealCopies(_ payload: PointPayload, sequence: UInt64) throws -> [SealedPoint] {
        let plaintext = try JSONEncoder().encode(payload)
        return try recipients.map { viewer in
            let box = try ChaChaPoly.seal(plaintext, using: key, authenticating: Data("\(shareID.raw)#\(sequence)".utf8))
            return SealedPoint(shareID: shareID, viewerID: viewer, sequence: sequence, sharerPublicKey: Data(), ciphertext: box.combined)
        }
    }
}

struct GroupKeyOpener: FanoutOpening {
    let viewerID: ViewerID
    let key: SymmetricKey
    func tryOpen(_ sealed: SealedPoint) -> PointPayload? {
        guard let box = try? ChaChaPoly.SealedBox(combined: sealed.ciphertext),
              let data = try? ChaChaPoly.open(box, using: key, authenticating: Data("\(sealed.shareID.raw)#\(sealed.sequence)".utf8))
        else { return nil }
        return try? JSONDecoder().decode(PointPayload.self, from: data)
    }
}

final class FanoutCryptoTests: XCTestCase {
    let share = ShareID("s1")
    let alice = ViewerKeys(viewerID: ViewerID("alice"))
    let bob = ViewerKeys(viewerID: ViewerID("bob"))
    let carol = ViewerKeys(viewerID: ViewerID("carol"))

    func payload(_ lat: Double = 12.9716, at ms: Int64 = 1_000) throws -> PointPayload {
        let fix = try XCTUnwrap(LocationFix(latitude: lat, longitude: 77.5946, accuracyMeters: 5, timestamp: Instant(millis: ms)))
        return PointPayload(fix: fix, sentAt: Instant(millis: ms), reason: .moved)
    }

    func sealer(_ keys: [ViewerKeys]) throws -> PerViewerSealer {
        var s = PerViewerSealer(shareID: share)
        for k in keys { try s.add(k.viewerID, publicKey: k.publicKey) }
        return s
    }

    func testEachViewerDecryptsTheirOwnCopyAndOnlyThat() throws {
        let p = try payload()
        let copies = try sealer([alice, bob]).sealCopies(p, sequence: 1)
        XCTAssertEqual(copies.map(\.viewerID), [alice.viewerID, bob.viewerID])
        guard copies.count == 2 else { return }
        XCTAssertEqual(try PerViewerOpener(keys: alice).open(copies[0]), p)
        XCTAssertEqual(try PerViewerOpener(keys: bob).open(copies[1]), p)
        XCTAssertNotEqual(copies[0].ciphertext, copies[1].ciphertext, "per-viewer keys, not one ciphertext fanned out")
        XCTAssertThrowsError(try PerViewerOpener(keys: alice).open(copies[1])) {
            XCTAssertEqual($0 as? FanoutCryptoError, .notAddressedToMe)
        }
    }

    func testCiphertextContainsNoCoordinates() throws {
        let copies = try sealer([alice]).sealCopies(try payload(), sequence: 1)
        let blob = try XCTUnwrap(copies.first).ciphertext
        XCTAssertNil(blob.range(of: Data("12.9716".utf8)))
        XCTAssertNil(blob.range(of: Data("latitude".utf8)))
        // And the control: the plaintext encoding *does* contain them, so the check above can fail.
        XCTAssertNotNil(try JSONEncoder().encode(try payload()).range(of: Data("12.9716".utf8)))
    }

    func testRelayCannotReaddressRenumberOrTamper() throws {
        let copies = try sealer([alice, bob]).sealCopies(try payload(), sequence: 7)
        let forAlice = try XCTUnwrap(copies.first)
        // Re-addressed to Bob: wrong key derivation and wrong associated data.
        XCTAssertThrowsError(try PerViewerOpener(keys: bob).open(forAlice.readdressed(to: bob.viewerID)))
        // Renumbered (to jump a replay window): the sequence is bound into the tag.
        let renumbered = SealedPoint(shareID: share, viewerID: alice.viewerID, sequence: 8,
                                     sharerPublicKey: forAlice.sharerPublicKey, ciphertext: forAlice.ciphertext)
        XCTAssertThrowsError(try PerViewerOpener(keys: alice).open(renumbered)) {
            XCTAssertEqual($0 as? FanoutCryptoError, .authenticationFailed)
        }
        // A flipped byte.
        var bytes = [UInt8](forAlice.ciphertext)
        guard bytes.count > 20 else { return XCTFail("ciphertext unexpectedly short") }
        bytes[20] ^= 0x01
        let tampered = SealedPoint(shareID: share, viewerID: alice.viewerID, sequence: 7,
                                   sharerPublicKey: forAlice.sharerPublicKey, ciphertext: Data(bytes))
        XCTAssertThrowsError(try PerViewerOpener(keys: alice).open(tampered))
        // A garbage sharer key.
        let badKey = SealedPoint(shareID: share, viewerID: alice.viewerID, sequence: 7, sharerPublicKey: Data([1, 2, 3]),
                                 ciphertext: forAlice.ciphertext)
        XCTAssertThrowsError(try PerViewerOpener(keys: alice).open(badKey)) {
            XCTAssertEqual($0 as? FanoutCryptoError, .badSharerKey)
        }
    }

    func testInboxRejectsReplayAndOutOfOrderCopies() throws {
        let s = try sealer([alice])
        let c3 = try XCTUnwrap(s.sealCopies(try payload(1, at: 3), sequence: 3).first)
        let c2 = try XCTUnwrap(s.sealCopies(try payload(2, at: 2), sequence: 2).first)
        var inbox = PointInbox(opener: PerViewerOpener(keys: alice))
        XCTAssertEqual(try inbox.receive(c3).fix.latitude, 1)
        XCTAssertThrowsError(try inbox.receive(c3)) { XCTAssertEqual($0 as? FanoutCryptoError, .staleOrReplayed(sequence: 3, lastSeen: 3)) }
        XCTAssertThrowsError(try inbox.receive(c2)) { XCTAssertEqual($0 as? FanoutCryptoError, .staleOrReplayed(sequence: 2, lastSeen: 3)) }
        XCTAssertEqual(inbox.latest[share]?.payload.fix.latitude, 1, "the pin never moves backwards")
    }

    func testRevokedViewerGetsNoFurtherCopies() throws {
        var s = try sealer([alice, bob, carol])
        XCTAssertEqual(try s.sealCopies(try payload(), sequence: 1).count, 3)
        s.revoke(carol.viewerID)
        let after = try s.sealCopies(try payload(at: 2_000), sequence: 2)
        XCTAssertEqual(after.map(\.viewerID), [alice.viewerID, bob.viewerID])
        let openers: [any FanoutOpening] = [PerViewerOpener(keys: alice), PerViewerOpener(keys: bob), PerViewerOpener(keys: carol)]
        XCTAssertEqual(FanoutAudit.crossReadable(after, openers: openers), [], "Carol cannot read Alice's or Bob's copy, even re-addressed")
    }

    func testAuditPassesThePerViewerSchemeAndCatchesTheGroupKeyScheme() throws {
        let p = try payload()
        let real = try sealer([alice, bob, carol]).sealCopies(p, sequence: 1)
        let realOpeners: [any FanoutOpening] = [alice, bob, carol].map { PerViewerOpener(keys: $0) }
        XCTAssertEqual(FanoutAudit.crossReadable(real, openers: realOpeners), [])

        // The broken scheme, after "revoking" Carol by dropping her from the recipient list —
        // she still holds the group key, so she reads everyone's copies.
        let key = SymmetricKey(size: .bits256)
        let broken = GroupKeySealer(shareID: share, recipients: [alice.viewerID, bob.viewerID], key: key)
        let brokenCopies = try broken.sealCopies(p, sequence: 2)
        let brokenOpeners: [any FanoutOpening] = [alice, bob, carol].map { GroupKeyOpener(viewerID: $0.viewerID, key: key) }
        let violations = FanoutAudit.crossReadable(brokenCopies, openers: brokenOpeners)
        XCTAssertFalse(violations.isEmpty, "the audit must fail a broken scheme, or it proves nothing")
        XCTAssertTrue(violations.contains(.init(sealedFor: alice.viewerID, readBy: carol.viewerID)))
    }

    func testBadViewerKeyIsRejectedAtAddTime() {
        var s = PerViewerSealer(shareID: share)
        XCTAssertThrowsError(try s.add(ViewerID("x"), publicKey: Data(repeating: 0, count: 5))) {
            XCTAssertEqual($0 as? FanoutCryptoError, .badSharerKey)
        }
        XCTAssertEqual(s.recipients, [])
    }

    func testAssociatedDataIsInjective() {
        let a = AssociatedData.make(ShareID("a|b"), ViewerID("c"), 1)
        let b = AssociatedData.make(ShareID("a"), ViewerID("b|c"), 1)
        XCTAssertNotEqual(a, b)
        XCTAssertNotEqual(AssociatedData.make(share, ViewerID("v"), 1), AssociatedData.make(share, ViewerID("v"), 2))
    }
}
