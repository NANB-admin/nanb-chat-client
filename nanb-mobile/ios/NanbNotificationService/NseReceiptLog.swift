import Foundation

/// Records the outcome of the extension's last closed-app delivered-receipt
/// attempt into the shared App Group, so the APP can report it.
///
/// Why this exists: the receipt runs in a separate process that iOS launches and
/// kills per push, with no console on a store build, and every failure mode is
/// silent by design (best-effort; the foreground catchup is the backstop). The
/// only previous way to see which stage failed was `debugBanner`, which requires
/// a special build and defaces the notification. One sideload of a normal build
/// plus one message now answers the question instead.
///
/// Contains no message content and no key material — a stage tag, an HTTP code
/// and a timestamp. Written with the same AfterFirstUnlock protection as the
/// inputs file so the extension can write it on a locked device.
enum NseReceiptLog {
    static let appGroup = "group.us.nanb.chat"
    static let fileName = "nse_last_receipt.json"

    /// Overwrites the record with this attempt's outcome. Best-effort: a failure
    /// to record must never affect the receipt or the banner.
    static func record(stage: String, http: Int?, note: String?) {
        guard let dir = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: appGroup) else { return }
        var payload: [String: Any] = [
            "stage": stage,
            "at": Int(Date().timeIntervalSince1970),
        ]
        if let http = http { payload["http"] = http }
        if let note = note, !note.isEmpty { payload["note"] = note }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        var url = dir.appendingPathComponent(fileName)
        try? data.write(to: url, options: [.completeFileProtectionUntilFirstUserAuthentication, .atomic])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }
}
