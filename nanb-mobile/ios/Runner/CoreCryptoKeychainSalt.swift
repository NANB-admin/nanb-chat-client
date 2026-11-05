import CryptoKit
import Foundation
// Explicit: SecItemDelete / kSecClass / errSecItemNotFound live in Security,
// and neither Foundation nor CryptoKit re-exports it.
import Security

/// The iOS-only half of CoreCrypto's keystore: its SQLCipher **salt**, which
/// lives in the iOS keychain rather than in the database file.
///
/// Why this exists — CoreCrypto's `ios_wal_compat` (keystore/src/connection/
/// platform/generic/ios_wal_compat.rs) sets `PRAGMA cipher_plaintext_header_size
/// = 32` so iOS can see the `SQLite format 3\0` magic and not kill a backgrounded
/// app doing WAL writes. Those first 32 bytes are exactly where SQLCipher
/// normally keeps the salt, so leaving them in plaintext **destroys** it — and
/// CoreCrypto therefore stashes the salt in the keychain instead, keyed by the
/// store path:
///
///     service = "wire.com"
///     account = "keystore_salt_" + hex(sha256(<utf8 store path>))
///
/// The consequence, and the bug this type exists to fix: **the db file and its
/// keychain salt are one unit.** Delete the file and leave the salt and the next
/// open re-applies a stale salt to a brand-new database; lose the salt and keep
/// the file (a re-signed install lands in a different keychain access group, so
/// the old item becomes invisible) and the salt can never be recovered from the
/// file, because the header that held it is plaintext now. Either half alone is
/// an unopenable store that reports itself as a bare
/// `Error code 1: SQL error or missing database`.
///
/// So: whenever `MlsClientHolder` deletes the store file, it deletes this too.
enum CoreCryptoKeychainSalt {
  /// Keychain service name CoreCrypto files the salt under. Hard-coded to
  /// `wire.com` upstream (`WIRE_SERVICE_NAME`); it is not configurable.
  private static let service = "wire.com"

  /// The keychain account name CoreCrypto derives for `path`. MUST stay
  /// byte-identical to the Rust side — `format!("keystore_salt_{}",
  /// hex::encode(sha2::Sha256::digest(path)))`, lowercase hex over the UTF-8
  /// bytes of the path string.
  static func account(forStorePath path: String) -> String {
    let digest = SHA256.hash(data: Data(path.utf8))
    let hex = digest.map { String(format: "%02x", $0) }.joined()
    return "keystore_salt_\(hex)"
  }

  /// Removes the salt item for `path`. Returns true when the item is gone
  /// afterwards — including when it was never there, which is the normal case
  /// on a first run and is NOT a failure.
  @discardableResult
  static func delete(forStorePath path: String) -> Bool {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account(forStorePath: path),
    ]
    let status = SecItemDelete(query as CFDictionary)
    return status == errSecSuccess || status == errSecItemNotFound
  }

  /// Re-files a salt orphaned by a store-PATH change under `path`'s account.
  /// Returns true when it moved one (the caller then retries the open).
  ///
  /// The account is derived from the ABSOLUTE store path, which embeds the
  /// Data-container UUID — and iOS does not promise that UUID survives an app
  /// update. When it moves, the db file moves with the container but its salt
  /// stays filed under the OLD path's hash, the open fails, and the purge that
  /// follows threw away every MLS group the user had ("Couldn't find
  /// conversation" on the next send to each one).
  ///
  /// Only acts on an unambiguous picture: exactly ONE `keystore_salt_` item for
  /// another path. An item already under the current account is the one the
  /// failed open just minted for a salt it couldn't find, so it is replaced.
  /// Wrong guesses are harmless — the store was not opening anyway, and the
  /// caller's purge still runs if the retry fails.
  static func adoptOrphan(forStorePath path: String) -> Bool {
    let current = account(forStorePath: path)
    let listQuery: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecMatchLimit as String: kSecMatchLimitAll,
      kSecReturnAttributes as String: true,
    ]
    var found: CFTypeRef?
    guard SecItemCopyMatching(listQuery as CFDictionary, &found) == errSecSuccess,
      let items = found as? [[String: Any]]
    else { return false }
    let orphans = items
      .compactMap { $0[kSecAttrAccount as String] as? String }
      .filter { $0.hasPrefix("keystore_salt_") && $0 != current }
    guard orphans.count == 1, let orphan = orphans.first else { return false }

    delete(forStorePath: path)
    let match: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: orphan,
    ]
    let update: [String: Any] = [kSecAttrAccount as String: current]
    return SecItemUpdate(match as CFDictionary, update as CFDictionary) == errSecSuccess
  }
}
