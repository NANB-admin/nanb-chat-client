import Flutter
import Foundation

/// Mirrors a small set of values from the Flutter app into the shared App Group
/// container so the Notification Service Extension — a separate process that
/// cannot read the app's keychain — can build the closed-app sealed "delivered"
/// receipt (see `IosSharedStore` on the Dart side and `NseSharedStore` in the
/// extension).
///
/// Method channel `nanb.app/shared_store`, method `write([String:String])`.
/// Written with COMPLETE-UNTIL-FIRST-USER-AUTHENTICATION file protection
/// (encrypted at rest; readable after the first unlock since boot, even when the
/// device is subsequently locked) and excluded from backups. This matches the
/// keychain `AfterFirstUnlock` class and Android's posture — REQUIRED so the
/// extension can read it for a push that lands on a locked phone (the common
/// case). Plain `Complete` (unlock-only) would make the receipt fire only while
/// the phone is actively unlocked, which is rarely true at push time.
///
/// SECURITY TRADEOFF — root identity keys at AfterFirstUnlock (residual, by
/// design; do not "fix" by tightening here — it breaks a shipped feature):
///   The values mirrored here (see `IosSharedStore.mirroredKeys` on the Dart
///   side) include BOTH the account's X25519 private key AND its Ed25519
///   IDENTITY SEED — the root identity. The NSE genuinely needs both: it opens
///   the outer seal with the X25519 key (`SealedSenderCrypto.open`) and it
///   Ed25519-SIGNS the delivered receipt with the seed (`DeliveredReceipt.sign`,
///   via `SealedReceiptSender`). Neither can be dropped without breaking the
///   closed-app sealed "delivered" receipt on a locked device.
///   This App Group file sits at `completeUntilFirstUserAuthentication`
///   (AfterFirstUnlock), which is WEAKER than the app keychain's
///   `WhenUnlockedThisDeviceOnly`: on a seized device that is locked but has been
///   unlocked once since boot, this file is decryptable, so the root identity is
///   forensically extractable. Tightening to `.complete` (unlock-only) would fix
///   the exposure but break locked-device background receipts (the whole reason
///   the NSE exists), so it is deliberately NOT done.
///   RECOMMENDED FUTURE FIX (needs Dart + protocol changes, out of scope for a
///   native-only edit): stop mirroring the ROOT identity. Derive and mirror only
///   a dedicated, receipt-scoped Ed25519 SIGNING SUBKEY (whose public half peers
///   register/trust for receipt verification) plus a transport/conversation-
///   scoped X25519 key — never the root seed — so a locked-device extraction of
///   this file cannot recover the account's root identity.
enum SharedStoreChannel {
    static let appGroup = "group.us.nanb.chat"
    static let fileName = "nse_shared.json"
    /// Written by the extension (`NseReceiptLog`), read-only from here.
    static let receiptFileName = "nse_last_receipt.json"

    static func register(with messenger: FlutterBinaryMessenger) {
        let channel = FlutterMethodChannel(name: "nanb.app/shared_store", binaryMessenger: messenger)
        channel.setMethodCallHandler { call, result in
            switch call.method {
            case "write":
                guard let map = call.arguments as? [String: String] else {
                    result(false)
                    return
                }
                result(write(map))
            case "readLastReceipt":
                result(readLastReceipt())
            default:
                result(FlutterMethodNotImplemented)
            }
        }
    }

    /// The raw JSON the extension wrote for its last delivered-receipt attempt
    /// (see `NseReceiptLog`), or nil if it has never run. Lets the app report
    /// which stage a store build actually reaches — the extension has no console
    /// and every failure there is silent by design.
    private static func readLastReceipt() -> String? {
        guard let dir = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: appGroup),
              let data = try? Data(contentsOf: dir.appendingPathComponent(receiptFileName)),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return json
    }

    private static func write(_ map: [String: String]) -> Bool {
        guard let dir = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: appGroup) else { return false }
        var url = dir.appendingPathComponent(fileName)
        do {
            let data = try JSONSerialization.data(withJSONObject: map)
            // AfterFirstUnlock-equivalent: the NSE must read this on a LOCKED
            // device. This exposes the mirrored root identity keys to a locked-
            // but-booted forensic extraction — a deliberate, documented tradeoff.
            // See the SECURITY TRADEOFF note on this enum for why it can't be
            // tightened here and the recommended future fix (mirror a derived
            // receipt subkey, not the root seed).
            try data.write(to: url, options: [.completeFileProtectionUntilFirstUserAuthentication, .atomic])
            // Don't let the device-bound key material ride into a backup.
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
            return true
        } catch {
            return false
        }
    }
}
