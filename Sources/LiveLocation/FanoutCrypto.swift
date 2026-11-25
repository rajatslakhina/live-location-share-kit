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
    /// The copy names a sharer key this viewer has not pinned for that share (or a different one).
    /// This is what stops a relay from minting its own key and sealing forged points.
    case untrustedSharerKey
    case badSharerKey
    case badViewerKey
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

    /// HKDF info binds the viewer ID *and both public keys*, so a derived key is only ever valid for this
    /// exact (sharer key, viewer key, viewer ID) triple.
    static func keyInfo(_ viewer: ViewerID, sharerKey: Data, viewerKey: Data) -> Data {
        var d = Data("LiveLocation.v1/viewer-key".utf8)
        for part in [Data(viewer.raw.utf8), sharerKey, viewerKey] {
            var len = UInt32(clamping: part.count).bigEndian
            withUnsafeBytes(of: &len) { d.append(contentsOf: $0) }
            d.append(part)
        }
        return d
    }
}

/// Fixed-size plaintext. Without padding the ciphertext length leaks the publish reason (the JSON for
/// "heartbeat" is longer than for "moved"). Padding removes that length signal only: heartbeats stay
/// identifiable from timing (they arrive TTL / 2 after the previous publish).
/// JSON tolerates trailing whitespace, so padding with spaces needs no framing.
enum Plaintext {
    static let bucket = 256

    static func pad(_ json: Data) -> Data {
        let buckets = max(1, (json.count + bucket - 1) / bucket)
        var out = json
        out.append(Data(repeating: 0x20, count: buckets * bucket - json.count))
        return out
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
    /// For persisting in the Keychain. Never send it anywhere.
    public var privateKeyRaw: Data { privateKey.rawRepresentation }

    public init(viewerID: ViewerID) {
        self.viewerID = viewerID
        self.privateKey = Curve25519.KeyAgreement.PrivateKey()
    }

    /// Restores a persisted key (after an app relaunch).
    public init(viewerID: ViewerID, privateKeyRaw: Data) throws {
        self.viewerID = viewerID
        do { self.privateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKeyRaw) }
        catch { throw FanoutCryptoError.badViewerKey }
    }
}

/// Sharer side. One X25519 key per share; each viewer's copy is sealed under
/// `HKDF(ECDH(shareKey, viewerKey), salt: shareID, info: viewerID ‖ sharerKey ‖ viewerKey)`, and the
/// AEAD tag binds (shareID, viewerID, sequence). Consequences, each with a test:
///  * the relay cannot read any copy, and cannot forge one: viewers only accept the sharer key they
///    pinned for the share (`PerViewerOpener.trust`), delivered out of band with the invitation;
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

    /// Restores a persisted share key so a share survives an app relaunch.
    public init(shareID: ShareID, privateKeyRaw: Data) throws {
        self.shareID = shareID
        do { self.shareKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKeyRaw) }
        catch { throw FanoutCryptoError.badSharerKey }
    }

    /// The key viewers pin for this share. Send it with the invitation, not via the relay.
    public var sharePublicKey: Data { shareKey.publicKey.rawRepresentation }
    /// For persisting in the Keychain. Never send it anywhere.
    public var privateKeyRaw: Data { shareKey.rawRepresentation }

    public var recipients: [ViewerID] { viewerKeys.keys.sorted() }

    /// Adds (or replaces) a viewer's public key. A trial key agreement runs here, so a malformed or
    /// low-order key is rejected up front instead of breaking a later publish.
    public mutating func add(_ viewer: ViewerID, publicKey: Data) throws {
        guard let key = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicKey),
              (try? shareKey.sharedSecretFromKeyAgreement(with: key)) != nil
        else { throw FanoutCryptoError.badViewerKey }
        viewerKeys[viewer] = key
    }

    public mutating func revoke(_ viewer: ViewerID) { viewerKeys[viewer] = nil }

    /// Seals one copy per recipient. A viewer whose copy cannot be sealed is skipped rather than
    /// failing everyone else's copy.
    public func sealCopies(_ payload: PointPayload, sequence: UInt64) throws -> [SealedPoint] {
        let plaintext = Plaintext.pad(try JSONEncoder().encode(payload))
        let sharerPub = sharePublicKey
        return recipients.compactMap { viewer in
            guard let pub = viewerKeys[viewer],
                  let secret = try? shareKey.sharedSecretFromKeyAgreement(with: pub) else { return nil }
            let key = Self.derive(secret, shareID, viewer, sharerKey: sharerPub, viewerKey: pub.rawRepresentation)
            guard let box = try? ChaChaPoly.seal(plaintext, using: key,
                                                 authenticating: AssociatedData.make(shareID, viewer, sequence))
            else { return nil }
            return SealedPoint(shareID: shareID, viewerID: viewer, sequence: sequence,
                               sharerPublicKey: sharerPub, ciphertext: box.combined)
        }
    }

    static func derive(_ secret: SharedSecret, _ share: ShareID, _ viewer: ViewerID,
                       sharerKey: Data, viewerKey: Data) -> SymmetricKey {
        secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(share.raw.utf8),
                                       sharedInfo: AssociatedData.keyInfo(viewer, sharerKey: sharerKey, viewerKey: viewerKey),
                                       outputByteCount: 32)
    }
}

/// Viewer side. Opens only copies whose sharer key was pinned for that share with `trust(_:sharerPublicKey:)`.
/// Stateless `tryOpen` for audits; `PointInbox` adds the replay window.
public struct PerViewerOpener: FanoutOpening {
    public let keys: ViewerKeys
    public private(set) var trustedSharers: [ShareID: Data] = [:]
    public var viewerID: ViewerID { keys.viewerID }

    public init(keys: ViewerKeys) { self.keys = keys }

    /// Pins the sharer key for a share — taken from the invitation, never from a relay-delivered copy.
    public mutating func trust(_ share: ShareID, sharerPublicKey: Data) { trustedSharers[share] = sharerPublicKey }
    public mutating func untrust(_ share: ShareID) { trustedSharers[share] = nil }

    public func open(_ sealed: SealedPoint) throws -> PointPayload {
        guard sealed.viewerID == viewerID else { throw FanoutCryptoError.notAddressedToMe }
        guard let pinned = trustedSharers[sealed.shareID], pinned == sealed.sharerPublicKey
        else { throw FanoutCryptoError.untrustedSharerKey }
        guard let sharerPub = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: pinned)
        else { throw FanoutCryptoError.badSharerKey }
        let plaintext: Data
        do {
            let secret = try keys.privateKey.sharedSecretFromKeyAgreement(with: sharerPub)
            let key = PerViewerSealer.derive(secret, sealed.shareID, viewerID, sharerKey: pinned, viewerKey: keys.publicKey)
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
///
/// The replay window lives in memory. An app that must reject replays across its own relaunches persists
/// `latest[share].sequence` (see README limits).
public struct PointInbox: Sendable {
    public private(set) var opener: PerViewerOpener
    public private(set) var latest: [ShareID: (sequence: UInt64, payload: PointPayload)] = [:]

    public init(opener: PerViewerOpener) { self.opener = opener }

    public mutating func trust(_ share: ShareID, sharerPublicKey: Data) {
        opener.trust(share, sharerPublicKey: sharerPublicKey)
    }

    @discardableResult
    public mutating func receive(_ sealed: SealedPoint) throws -> PointPayload {
        if let last = latest[sealed.shareID], sealed.sequence <= last.sequence {
            throw FanoutCryptoError.staleOrReplayed(sequence: sealed.sequence, lastSeen: last.sequence)
        }
        let payload = try opener.open(sealed)
        latest[sealed.shareID] = (sealed.sequence, payload)
        return payload
    }

    /// Drops the pin and the replay state for a share that ended or was revoked.
    public mutating func forget(_ share: ShareID) {
        latest[share] = nil
        opener.untrust(share)
    }
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
