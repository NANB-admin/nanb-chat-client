import Flutter
import Foundation

/// Collects what the share extension left in the App Group container and hands
/// it to Dart — the iOS half of `nanb.app/incoming_share` (Android's half lives
/// in `IncomingShareStore.kt`).
///
/// Method channel `nanb.app/incoming_share`, method `takePending`. Returns the
/// payload once and CLEARS it, so the same share can never open the picker
/// twice — Dart pulls on cold start and on every foreground.
///
/// The three names below duplicate `SharedInbox` in the NanbShareExtension
/// target ON PURPOSE: separate targets can't share code, so they describe the
/// same on-disk layout from both sides and must be changed together (the same
/// arrangement as `SharedStoreChannel` / `NseSharedStore`).
enum IncomingShareChannel {
    static let appGroup = "group.us.nanb.chat"
    static let inboxDirName = "incoming_share"
    static let payloadFileName = "pending_share.json"

    /// How long an orphaned attachment may sit in the inbox before it's swept.
    /// Files are normally deleted by Dart the moment the share is sent; this
    /// only catches copies whose share was abandoned (the user backed out of
    /// the picker, or the app was killed before collecting them), so the user's
    /// plaintext content doesn't accumulate in the container forever.
    private static let staleAfter: TimeInterval = 24 * 60 * 60

    static func register(with messenger: FlutterBinaryMessenger) {
        let channel = FlutterMethodChannel(
            name: "nanb.app/incoming_share", binaryMessenger: messenger)
        channel.setMethodCallHandler { call, result in
            guard call.method == "takePending" else {
                result(FlutterMethodNotImplemented)
                return
            }
            let payload = takePending()
            purgeStaleAttachments(keeping: payload)
            result(payload)
        }
    }

    /// Reads and deletes the pending payload. Only the small JSON is touched
    /// here — the attachments themselves are read (and deleted) by Dart, which
    /// already does that work off the UI thread for in-app attachments.
    private static func takePending() -> [String: Any]? {
        guard let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: appGroup) else { return nil }
        let url = container.appendingPathComponent(payloadFileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        // Delete first: a payload we failed to parse must not be retried on
        // every single foreground.
        try? FileManager.default.removeItem(at: url)
        guard let decoded = try? JSONSerialization.jsonObject(with: data),
              let payload = decoded as? [String: Any] else { return nil }
        return payload
    }

    /// Removes inbox files older than [staleAfter], skipping anything named by
    /// the payload we are handing over right now.
    private static func purgeStaleAttachments(keeping payload: [String: Any]?) {
        guard let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: appGroup) else { return }
        let directory = container.appendingPathComponent(inboxDirName, isDirectory: true)
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        var live = Set<String>()
        if let attachments = payload?["attachments"] as? [[String: String]] {
            for attachment in attachments {
                if let path = attachment["path"] { live.insert(path) }
            }
        }
        let cutoff = Date().addingTimeInterval(-staleAfter)
        for entry in entries where !live.contains(entry.path) {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            if let modified, modified > cutoff { continue }
            try? manager.removeItem(at: entry)
        }
    }
}
