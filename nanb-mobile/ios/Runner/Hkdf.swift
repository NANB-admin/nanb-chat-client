import CryptoKit
import Foundation

/// RFC 5869 HKDF using HMAC-SHA256. Mirror of the Android `Hkdf` object
/// (nanb_crypto/.../Hkdf.kt). Used only to derive CoreCrypto's
/// store-encryption key from the user's identity seed.
///
/// We hand-roll extract/expand on top of CryptoKit's `HMAC<SHA256>` rather
/// than using `HKDF<SHA256>.deriveKey` so the byte-for-byte output matches
/// the Kotlin implementation exactly (same `salt = ByteArray(0)` → zero-filled
/// 32-byte salt convention, same single-shot `info`). A mismatch here would
/// derive a different store key than Android and make a cross-platform restore
/// of the SAME identity unable to open a store written by the other platform —
/// though in practice each device has its own store, so this is belt-and-braces.
enum Hkdf {
  /// Derives `length` bytes of key material from `ikm`.
  /// - `salt`: if empty, RFC 5869 says use a string of `HashLen` zeros.
  ///   We match the Kotlin: empty → 32 zero bytes.
  static func derive(ikm: Data, salt: Data, info: Data, length: Int) -> Data {
    precondition(length >= 1 && length <= 255 * 32, "length out of range: \(length)")
    let effectiveSalt = salt.isEmpty ? Data(repeating: 0, count: 32) : salt
    let prk = extract(ikm: ikm, salt: effectiveSalt)
    return expand(prk: prk, info: info, length: length)
  }

  private static func extract(ikm: Data, salt: Data) -> Data {
    let key = SymmetricKey(data: salt)
    let mac = HMAC<SHA256>.authenticationCode(for: ikm, using: key)
    return Data(mac)
  }

  private static func expand(prk: Data, info: Data, length: Int) -> Data {
    let key = SymmetricKey(data: prk)
    var out = Data()
    var t = Data()
    var counter: UInt8 = 1
    while out.count < length {
      var input = Data()
      input.append(t)
      input.append(info)
      input.append(counter)
      let block = HMAC<SHA256>.authenticationCode(for: input, using: key)
      t = Data(block)
      out.append(t)
      counter = counter &+ 1
    }
    return out.prefix(length)
  }
}
