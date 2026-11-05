import Foundation
import CryptoKit

/// Swift/CryptoKit port of the sealed-sender outer-envelope wire format and the
/// inner record, mirroring `nanb-mobile/lib/core/crypto/sealed_envelope.dart`
/// and `sealed_inner.dart` EXACTLY (byte-for-byte) so a blob opened/sealed here
/// interoperates with the Flutter app and peers.
///
/// Outer wire format (v2):
///   byte 0      version (0x02 padded; 0x01 = legacy unpadded, still openable)
///   bytes 1..33 ephemeral X25519 public key (32)
///   bytes 33..45 AES-GCM nonce (12)
///   bytes 45..   AES-256-GCM ciphertext, 16-byte tag as the suffix
/// v2 AEAD plaintext = uint32 BE real-length || plaintext || zero pad to bucket.
/// key = HKDF-SHA256(ikm = ECDH(eph, recipient), salt = "nanb/sealed-sender/v1",
///                   info = recipient X25519 pub, L = 32).
enum SealedSenderCrypto {
    enum CryptoError: Error { case malformed, unsupportedVersion }

    static let salt = Array("nanb/sealed-sender/v1".utf8)
    static let legacyVersion: UInt8 = 0x01
    static let paddedVersion: UInt8 = 0x02
    static let pubLen = 32
    static let nonceLen = 12
    static let tagLen = 16
    static let buckets = [256, 1024, 4096, 16384, 65536]

    static func bucketFor(_ n: Int) -> Int {
        for b in buckets where n <= b { return b }
        let top = buckets.last!
        return ((n + top - 1) / top) * top
    }

    private static func pad(_ plaintext: [UInt8]) -> [UInt8] {
        let n = plaintext.count
        var out = [UInt8](repeating: 0, count: bucketFor(4 + n))
        out[0] = UInt8((n >> 24) & 0xFF)
        out[1] = UInt8((n >> 16) & 0xFF)
        out[2] = UInt8((n >> 8) & 0xFF)
        out[3] = UInt8(n & 0xFF)
        if n > 0 { out.replaceSubrange(4..<(4 + n), with: plaintext) }
        return out
    }

    private static func unpad(_ padded: [UInt8]) throws -> [UInt8] {
        guard padded.count >= 4 else { throw CryptoError.malformed }
        let n = (Int(padded[0]) << 24) | (Int(padded[1]) << 16)
            | (Int(padded[2]) << 8) | Int(padded[3])
        guard n >= 0, 4 + n <= padded.count else { throw CryptoError.malformed }
        return Array(padded[4..<(4 + n)])
    }

    private static func hkdfKey(shared: SharedSecret, recipientPub: Data) -> SymmetricKey {
        return shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(salt),
            sharedInfo: recipientPub,
            outputByteCount: 32)
    }

    /// Opens a sealed blob addressed to this device using its 32-byte X25519
    /// private key. Throws on a wrong key / corrupt blob (AEAD tag mismatch).
    static func open(sealed: [UInt8], recipientX25519Priv: Data) throws -> [UInt8] {
        let minLen = 1 + pubLen + nonceLen + tagLen
        guard sealed.count >= minLen else { throw CryptoError.malformed }
        let ver = sealed[0]
        guard ver == legacyVersion || ver == paddedVersion else {
            throw CryptoError.unsupportedVersion
        }
        let ephPub = Array(sealed[1..<(1 + pubLen)])
        let nonce = Array(sealed[(1 + pubLen)..<(1 + pubLen + nonceLen)])
        let tag = Array(sealed[(sealed.count - tagLen)...])
        let ct = Array(sealed[(1 + pubLen + nonceLen)..<(sealed.count - tagLen)])

        let priv = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: recipientX25519Priv)
        let recipientPub = priv.publicKey.rawRepresentation
        let ephPublic = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: Data(ephPub))
        let shared = try priv.sharedSecretFromKeyAgreement(with: ephPublic)
        let key = hkdfKey(shared: shared, recipientPub: recipientPub)

        let box = try AES.GCM.SealedBox(
            nonce: try AES.GCM.Nonce(data: Data(nonce)),
            ciphertext: Data(ct),
            tag: Data(tag))
        let clear = try AES.GCM.open(box, using: key)
        return ver == paddedVersion ? try unpad([UInt8](clear)) : [UInt8](clear)
    }

    /// Seals [plaintext] for the device owning [recipientX25519Pub] (32 bytes),
    /// emitting the v2 padded wire blob the server stores/relays.
    static func seal(plaintext: [UInt8], recipientX25519Pub: Data) throws -> [UInt8] {
        let recipientPublic = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: recipientX25519Pub)
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let ephPub = ephemeral.publicKey.rawRepresentation
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: recipientPublic)
        let key = hkdfKey(shared: shared, recipientPub: recipientX25519Pub)

        let box = try AES.GCM.seal(Data(pad(plaintext)), using: key)
        var out = [UInt8]()
        out.append(paddedVersion)
        out.append(contentsOf: ephPub)
        out.append(contentsOf: Data(box.nonce))
        out.append(contentsOf: box.ciphertext)
        out.append(contentsOf: box.tag)
        return out
    }
}

/// Port of `sealed_inner.dart`: the record carried inside a sealed envelope.
///   version(1) | convLen(2 BE) conv | typeLen(1) type | sndLen(2 BE) snd | ciphertext
struct SealedInner {
    let conversationId: String
    let envelopeType: String
    let senderDeviceId: String
    let ciphertext: [UInt8]

    static let version: UInt8 = 0x01

    func encode() -> [UInt8] {
        let conv = Array(conversationId.utf8)
        let type = Array(envelopeType.utf8)
        let snd = Array(senderDeviceId.utf8)
        var out = [UInt8]()
        out.append(SealedInner.version)
        out.append(UInt8((conv.count >> 8) & 0xFF))
        out.append(UInt8(conv.count & 0xFF))
        out.append(contentsOf: conv)
        out.append(UInt8(type.count & 0xFF))
        out.append(contentsOf: type)
        out.append(UInt8((snd.count >> 8) & 0xFF))
        out.append(UInt8(snd.count & 0xFF))
        out.append(contentsOf: snd)
        out.append(contentsOf: ciphertext)
        return out
    }

    static func decode(_ bytes: [UInt8]) throws -> SealedInner {
        guard let first = bytes.first, first == version else {
            throw SealedSenderCrypto.CryptoError.malformed
        }
        var off = 1
        func u8() throws -> Int {
            guard off + 1 <= bytes.count else { throw SealedSenderCrypto.CryptoError.malformed }
            defer { off += 1 }
            return Int(bytes[off])
        }
        func u16() throws -> Int {
            guard off + 2 <= bytes.count else { throw SealedSenderCrypto.CryptoError.malformed }
            let v = (Int(bytes[off]) << 8) | Int(bytes[off + 1])
            off += 2
            return v
        }
        func take(_ n: Int) throws -> [UInt8] {
            guard off + n <= bytes.count else { throw SealedSenderCrypto.CryptoError.malformed }
            defer { off += n }
            return Array(bytes[off..<(off + n)])
        }
        let conv = String(decoding: try take(try u16()), as: UTF8.self)
        let type = String(decoding: try take(try u8()), as: UTF8.self)
        let snd = String(decoding: try take(try u16()), as: UTF8.self)
        let ct = Array(bytes[off...])
        return SealedInner(conversationId: conv, envelopeType: type,
                           senderDeviceId: snd, ciphertext: ct)
    }
}
