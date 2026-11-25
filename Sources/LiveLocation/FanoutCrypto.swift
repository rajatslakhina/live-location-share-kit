import Foundation
import CryptoKit

/// What a viewer learns after decrypting one copy.
public struct PointPayload: Hashable, Sendable, Codable {
    public let fix: LocationFix
    /// When the sharer sent it. A heartbeat re-sends an old `fix` with a new `sentAt`, which is how a
    /// viewer tells "still here, hasn't moved" from "gone quiet".
    public let sentAt: Instant
    public let reason: PublishReason

    public init(fix: LocationFix, sentAt: Instant, reason: PublishReason) {
        self.fix = fix
        self.sentAt = sentAt
        self.reason = reason
    }
}

/// One viewer's encrypted copy of one point. The relay stores and forwards these; it can read only the
/// routing header (share, viewer, sequence), never the coordinates.
public struct SealedPoint: Hashable, Sendable, Codable {
    public let shareID: ShareID
    public let viewerID: ViewerID
    /// Strictly increasing per share. Bound into the AEAD tag, so the relay cannot renumber a copy.
    public let sequence: UInt64
    /// The share's X25519 public key (raw 32 bytes); the viewer needs it for key agreement.
    public let sharerPublicKey: Data
    /// ChaCha20-Poly1305 combined box (nonce ‖ ciphertext ‖ tag).
    public let ciphertext: Data

    public init(shareID: ShareID, viewerID: ViewerID, sequence: UInt64, sharerPublicKey: Data, ciphertext: Data) {
        self.shareID = shareID
        self.viewerID = viewerID
        self.sequence = sequence
        self.sharerPublicKey = sharerPublicKey
        self.ciphertext = ciphertext
    }

    /// Wire size estimate used by the load model: payload bytes plus the routing header.
    public var approximateByteCount: Int {
        Saturating.add(Saturating.add(ciphertext.count, sharerPublicKey.count),
                       Saturating.add(shareID.raw.utf8.count, Saturating.add(viewerID.raw.utf8.count, 8)))
    }

    /// Same envelope, re-addressed. Used by `FanoutAudit` to model a relay that forwards a copy to the
    /// wrong viewer.
    func readdressed(to viewer: ViewerID) -> SealedPoint {
        SealedPoint(shareID: shareID, viewerID: viewer, sequence: sequence,
                    sharerPublicKey: sharerPublicKey, ciphertext: ciphertext)
    }
}

public enum FanoutCryptoError: Error, Equatable, Sendable {
    case notAddressedToMe
    case staleOrReplayed(sequence: UInt64, lastSeen: UInt64)
    case badSharerKey
    case authenticationFailed
    case malformedPayload
}

/// Length-prefixed associated data. A naive `"\(share)|\(viewer)|\(seq)"` would let `("a|b", "c")` and
/// `("a", "b|c")` produce the same bytes; length prefixes make the encoding injective.
enum AssociatedData {
    static func make(_ share: ShareID, _ viewer: ViewerID, _ sequence: UInt64) -> Data {
        var d = Data("LiveLocation.v1".utf8)
        for part in [Data(share.raw.utf8), Data(viewer.raw.utf8)] {
            var len = UInt32(clamping: part.count).bigEndian
            withUnsafeBytes(of: &len) { d.append(contentsOf: $0) }
            d.append(part)
        }
        var seq = sequence.bigEndian
        withUnsafeBytes(of: &seq) { d.append(contentsOf: $0) }
        return d
    }

    static func keyInfo(_ viewer: ViewerID) -> Data {
        var d = Data("LiveLocation.v1/viewer-key".utf8)
        d.append(Data(viewer.raw.utf8))
        return d
    }
}

// MARK: - Seal / open seams (for the audit and for alternative schemes)

public protocol FanoutSealing: Sendable {
    var shareID: ShareID { get }
    var recipients: [ViewerID] { get }
    func sealCopies(_ payload: PointPayload, sequence: UInt64) throws -> [SealedPoint]
}

public protocol FanoutOpening: Sendable {
    var viewerID: ViewerID { get }
    /// Stateless open (no replay window): returns nil if this viewer cannot decrypt the copy.
    func tryOpen(_ sealed: SealedPoint) -> PointPayload?
}

// MARK: - Per-viewer sealing (the real scheme)

/// A viewer's long-term key pair. Only the public half ever leaves the device.
public struct ViewerKeys: Sendable {
    public let viewerID: ViewerID
    let privateKey: Curve25519.KeyAgreement.PrivateKey
    public var publicKey: Data { privateKey.publicKey.rawRepresentation }

    public init(viewerID: ViewerID) {
        self.viewerID = viewerID
        self.privateKey = Curve25519.KeyAgreement.PrivateKey()
    }
}

/// Sharer side. One X25519 key per share; each viewer's copy is sealed under
/// `HKDF(ECDH(shareKey, viewerKey), salt: shareID, info: viewerID)`, and the AEAD tag binds
/// (shareID, viewerID, sequence). Consequences, each with a test:
///  * the relay cannot read any copy;
///  * a copy re-addressed to another viewer fails authentication;
///  * after `revoke`, no copy is ever produced for the revoked key — revocation is enforced by the
///    sharer's own device, not by trusting the relay to stop forwarding.
public struct PerViewerSealer: FanoutSealing {
    public let shareID: ShareID
    private let shareKey: Curve25519.KeyAgreement.PrivateKey
    private var viewerKeys: [ViewerID: Curve25519.KeyAgreement.PublicKey] = [:]

    public init(shareID: ShareID) {
        self.shareID = shareID
        self.shareKey = Curve25519.KeyAgreement.PrivateKey()
    }

    public var recipients: [ViewerID] { viewerKeys.keys.sorted() }

    /// Adds (or replaces) a viewer's public key. Throws for a key that is not 32 valid bytes.
    public mutating func add(_ viewer: ViewerID, publicKey: Data) throws {
        do { viewerKeys[viewer] = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicKey) }
        catch { throw FanoutCryptoError.badSharerKey }
    }

    public mutating func revoke(_ viewer: ViewerID) { viewerKeys[viewer] = nil }

    public func sealCopies(_ payload: PointPayload, sequence: UInt64) throws -> [SealedPoint] {
        let plaintext = try JSONEncoder().encode(payload)
        let sharerPub = shareKey.publicKey.rawRepresentation
        return try recipients.compactMap { viewer in
            guard let pub = viewerKeys[viewer] else { return nil }
            let key = try Self.derive(shareKey.sharedSecretFromKeyAgreement(with: pub), shareID, viewer)
            let box = try ChaChaPoly.seal(plaintext, using: key,
                                          authenticating: AssociatedData.make(shareID, viewer, sequence))
            return SealedPoint(shareID: shareID, viewerID: viewer, sequence: sequence,
                               sharerPublicKey: sharerPub, ciphertext: box.combined)
        }
    }

    static func derive(_ secret: SharedSecret, _ share: ShareID, _ viewer: ViewerID) -> SymmetricKey {
        secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(share.raw.utf8),
                                       sharedInfo: AssociatedData.keyInfo(viewer), outputByteCount: 32)
    }
}

/// Viewer side. Stateless `tryOpen` for audits; `PointInbox` adds the replay window.
public struct PerViewerOpener: FanoutOpening {
    public let keys: ViewerKeys
    public var viewerID: ViewerID { keys.viewerID }

    public init(keys: ViewerKeys) { self.keys = keys }

    public func open(_ sealed: SealedPoint) throws -> PointPayload {
        guard sealed.viewerID == viewerID else { throw FanoutCryptoError.notAddressedToMe }
        guard let sharerPub = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: sealed.sharerPublicKey)
        else { throw FanoutCryptoError.badSharerKey }
        let plaintext: Data
        do {
            let secret = try keys.privateKey.sharedSecretFromKeyAgreement(with: sharerPub)
            let key = PerViewerSealer.derive(secret, sealed.shareID, viewerID)
            let box = try ChaChaPoly.SealedBox(combined: sealed.ciphertext)
            plaintext = try ChaChaPoly.open(box, using: key,
                                            authenticating: AssociatedData.make(sealed.shareID, viewerID, sealed.sequence))
        } catch {
            throw FanoutCryptoError.authenticationFailed
        }
        guard let payload = try? JSONDecoder().decode(PointPayload.self, from: plaintext)
        else { throw FanoutCryptoError.malformedPayload }
        return payload
    }

    public func tryOpen(_ sealed: SealedPoint) -> PointPayload? { try? open(sealed) }
}

/// The viewer's receive path: decrypt, then enforce a per-share monotonic sequence so a replayed or
/// reordered copy can never move a pin backwards.
public struct PointInbox: Sendable {
    public let opener: PerViewerOpener
    public private(set) var latest: [ShareID: (sequence: UInt64, payload: PointPayload)] = [:]

    public init(opener: PerViewerOpener) { self.opener = opener }

    @discardableResult
    public mutating func receive(_ sealed: SealedPoint) throws -> PointPayload {
        if let last = latest[sealed.shareID], sealed.sequence <= last.sequence {
            throw FanoutCryptoError.staleOrReplayed(sequence: sealed.sequence, lastSeen: last.sequence)
        }
        let payload = try opener.open(sealed)
        latest[sealed.shareID] = (sealed.sequence, payload)
        return payload
    }

    public mutating func forget(_ share: ShareID) { latest[share] = nil }
}

// MARK: - Audit

/// Checks the property the README's privacy claim rests on: **no viewer can read a copy that was not
/// sealed for them**, including a copy the relay re-addresses to them.
public enum FanoutAudit {
    public struct Violation: Hashable, Sendable {
        public let sealedFor: ViewerID
        public let readBy: ViewerID
    }

    public static func crossReadable(_ copies: [SealedPoint], openers: [any FanoutOpening]) -> [Violation] {
        var out: [Violation] = []
        for copy in copies {
            for opener in openers where opener.viewerID != copy.viewerID {
                let asIs = opener.tryOpen(copy) != nil
                let readdressed = opener.tryOpen(copy.readdressed(to: opener.viewerID)) != nil
                if asIs || readdressed { out.append(Violation(sealedFor: copy.viewerID, readBy: opener.viewerID)) }
            }
        }
        return out
    }
}
