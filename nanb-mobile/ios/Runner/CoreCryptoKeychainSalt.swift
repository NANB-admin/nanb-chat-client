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

  /// The salts filed under any path other than `path`, most recently modified
  /// first, since the newest is the likeliest to belong to the live db file.
  ///
  /// The account is derived from the ABSOLUTE store path, which embeds the
  /// Data-container UUID, and iOS does not promise that UUID survives an app
  /// update. When it moves, the db file moves with the container but its salt
  /// stays filed under the OLD path's hash, so the open fails.
  static func orphans(forStorePath path: String) -> [String] {
    let current = account(forStorePath: path)
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecMatchLimit as String: kSecMatchLimitAll,
      kSecReturnAttributes as String: true,
    ]
    var found: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &found) == errSecSuccess,
      let items = found as? [[String: Any]]
    else { return [] }
    return items
      .filter { ($0[kSecAttrAccount as String] as? String)?.hasPrefix("keystore_salt_") == true }
      .filter { ($0[kSecAttrAccount as String] as? String) != current }
      .sorted {
        let a = $0[kSecAttrModificationDate as String] as? Date ?? .distantPast
        let b = $1[kSecAttrModificationDate as String] as? Date ?? .distantPast
        return a > b
      }
      .compactMap { $0[kSecAttrAccount as String] as? String }
  }

  /// Files a COPY of the `orphan` salt under `path`'s account, replacing what is
  /// there (the item a failed open minted for a salt it couldn't find). A copy so
  /// a wrong candidate costs nothing: the caller just tries the next one.
  static func adopt(orphan: String, forStorePath path: String) -> Bool {
    let read: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: orphan,
      kSecReturnData as String: true,
    ]
    var found: CFTypeRef?
    guard SecItemCopyMatching(read as CFDictionary, &found) == errSecSuccess,
      let salt = found as? Data
    else { return false }
    delete(forStorePath: path)
    let add: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account(forStorePath: path),
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
      kSecValueData as String: salt,
    ]
    return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
  }

  /// Deletes every salt except `path`'s. Call only once `path`'s store has opened
  /// or been purged: there is one store per install, so the rest are dead. They
  /// outlive the app (the keychain survives a reinstall) and would otherwise pile
  /// up, one per container move.
  static func deleteOrphans(forStorePath path: String) {
    for orphan in orphans(forStorePath: path) {
      let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: orphan,
      ]
      SecItemDelete(query as CFDictionary)
    }
  }
}
