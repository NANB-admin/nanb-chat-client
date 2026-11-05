import Foundation

/// Reads the values the app mirrored into the shared App Group container
/// (`SharedStoreChannel` on the app side) so this extension can build the sealed
/// "delivered" receipt. The app's keychain is NOT reachable from the extension;
/// the App Group container is. Keys are the same SecureStorage keys the app uses
/// (e.g. `crypto.identity.x25519_priv.b64`).
///
/// Loaded once per extension invocation. Returns nil for everything if the file
/// is absent or unreadable — e.g. the device is locked (the file uses complete
/// protection), in which case the receipt is simply skipped (foreground catchup
/// is the backstop), exactly as with the keychain's WhenUnlocked items.
enum NseSharedStore {
    static let appGroup = "group.us.nanb.chat"
    static let fileName = "nse_shared.json"

    private static let values: [String: String] = {
        guard let dir = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: appGroup),
              let data = try? Data(contentsOf: dir.appendingPathComponent(fileName)),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let map = obj as? [String: String] else { return [:] }
        return map
    }()

    /// The stored string for [key], or nil if absent/empty.
    static func string(_ key: String) -> String? {
        guard let v = values[key], !v.isEmpty else { return nil }
        return v
    }

    /// A base64-encoded value decoded to raw bytes.
    static func base64Bytes(_ key: String) -> Data? {
        guard let s = string(key), let d = Data(base64Encoded: s) else { return nil }
        return d
    }
}
