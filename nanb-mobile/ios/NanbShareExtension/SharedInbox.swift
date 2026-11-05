import Foundation
import UniformTypeIdentifiers

/// The share extension's half of the App Group hand-off: where content the user
/// shared into Chat is parked until the app collects it.
///
/// A share extension is a SEPARATE PROCESS with no way to talk to the running
/// app, so the payload goes through the shared App Group container:
///
///   <group container>/incoming_share/<uuid>.<ext>   the copied files
///   <group container>/pending_share.json            what was shared
///
/// The Runner side reads and clears exactly this layout in
/// `IncomingShareChannel.swift` — the two files are separate TARGETS and cannot
/// share code, so the three names below are duplicated there ON PURPOSE and
/// must be changed together (same arrangement as
/// `SharedStoreChannel` / `NseSharedStore`).
///
/// FILE PROTECTION: everything here is written `.completeFileProtection`
/// (unlock-only). Unlike the Notification Service Extension's mirror — which
/// must be readable on a LOCKED device and is therefore weakened to
/// after-first-unlock — a share only ever happens with the user actively
/// driving an unlocked phone, and the app reads it while equally unlocked. So
/// this plaintext copy of the user's content gets the STRONGEST class
/// available; don't weaken it to match the NSE store.
enum SharedInbox {
    static let appGroup = "group.us.nanb.chat"
    static let inboxDirName = "incoming_share"
    static let payloadFileName = "pending_share.json"

    /// Copies a shared file (a URL handed over by the item provider) into the
    /// group container. Returns the attachment descriptor for the payload, or
    /// nil when the source can't be read.
    ///
    /// Uses `FileManager.copyItem` and stamps the protection class afterwards,
    /// rather than `Data(contentsOf:)` + write: a share extension runs under a
    /// memory limit far below the 100 MB media ceiling, so reading a shared
    /// VIDEO into memory to write it back out gets the extension jettisoned by
    /// the OS. copyItem never materialises the file.
    static func copy(from source: URL) -> [String: String]? {
        guard let directory = inboxDirectory() else { return nil }
        let name = source.lastPathComponent
        let target = directory.appendingPathComponent(
            "\(UUID().uuidString).\(source.pathExtension)")
        // A file URL from Files.app / another app's container is
        // security-scoped; without this the copy fails with a permission error.
        // Providers that hand over an unscoped temp URL return false here, which
        // is fine — the copy works either way.
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        do {
            try FileManager.default.copyItem(at: source, to: target)
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.complete],
                ofItemAtPath: target.path)
        } catch {
            return nil
        }
        return descriptor(target: target, name: name, ext: source.pathExtension)
    }

    /// Writes shared bytes that arrived as raw data (a screenshot, an image the
    /// provider rendered for us) into the group container.
    static func write(data: Data, fileExtension: String) -> [String: String]? {
        guard let directory = inboxDirectory() else { return nil }
        let target = directory.appendingPathComponent(
            "\(UUID().uuidString).\(fileExtension)")
        do {
            try data.write(to: target, options: [.completeFileProtection, .atomic])
        } catch {
            return nil
        }
        return descriptor(
            target: target, name: target.lastPathComponent, ext: fileExtension)
    }

    /// Writes the payload the app collects. Written LAST, after every
    /// attachment is on disk, so the app can never observe a payload that
    /// points at files which aren't there yet.
    static func writePayload(text: String, attachments: [[String: String]]) -> Bool {
        guard let container = containerURL() else { return false }
        let target = container.appendingPathComponent(payloadFileName)
        let payload: [String: Any] = ["text": text, "attachments": attachments]
        do {
            let data = try JSONSerialization.data(withJSONObject: payload)
            try data.write(to: target, options: [.completeFileProtection, .atomic])
            return true
        } catch {
            return false
        }
    }

    private static func descriptor(
        target: URL, name: String, ext: String
    ) -> [String: String] {
        let mime = UTType(filenameExtension: ext)?.preferredMIMEType
            ?? "application/octet-stream"
        return [
            "path": target.path,
            "name": name.isEmpty ? target.lastPathComponent : name,
            "mime": mime,
        ]
    }

    private static func containerURL() -> URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroup)
    }

    private static func inboxDirectory() -> URL? {
        guard let container = containerURL() else { return nil }
        let directory = container.appendingPathComponent(inboxDirName, isDirectory: true)
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
        }
        return directory
    }
}
