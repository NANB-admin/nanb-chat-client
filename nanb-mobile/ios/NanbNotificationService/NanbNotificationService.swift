import Foundation
import UserNotifications

/// Notification Service Extension — iOS launches this on every push that carries
/// `mutable-content`, giving ~30 s of native runtime BEFORE the banner shows.
/// It is the iOS counterpart of Android's FCM background isolate: iOS displays a
/// visible alert without running any Dart code, so this is the only place we can
/// send the closed-app sealed "delivered" receipt (see [SealedReceiptSender]).
///
/// The body stays generic ("New message") — the server is blind to the E2EE
/// content and (under sealed sender) to the sender, so there is nothing to
/// preview, exactly like Android's wake notification.
class NanbNotificationService: UNNotificationServiceExtension {
    /// Bring-up diagnostics: when true, append the receipt stage + HTTP code to
    /// the banner so an on-device test shows exactly where the flow got to.
    /// Production: false (clean "New message" — the receipt still runs silently).
    static let debugBanner = false

    var contentHandler: ((UNNotificationContent) -> Void)?
    var bestAttemptContent: UNMutableNotificationContent?

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        self.contentHandler = contentHandler
        self.bestAttemptContent = request.content.mutableCopy() as? UNMutableNotificationContent

        guard let content = bestAttemptContent else {
            contentHandler(request.content)
            return
        }

        let info = request.content.userInfo
        let envelopeId = info["envelope_id"] as? String
        let pushKind = info["push_kind"] as? String
        let sealedB64 = info["sealed_payload"] as? String

        // Normalise the body for a MESSAGE only. An incoming call arrives with
        // "Incoming call" (set by the server's APNs payload) and must KEEP it:
        // rewriting every push unconditionally relabelled every ring as "New
        // message", so a call that woke a locked phone was indistinguishable
        // from a chat message and nobody answered it.
        if pushKind != "call" {
            content.body = "New message"
        }

        // Only act on a non-silent push that inlined the outer sealed blob. (We
        // only set mutable-content on visible alerts, so a silent push won't even
        // reach here — this is defensive.) Otherwise just show the banner; the
        // receipt fires on the next foreground catchup as before.
        guard pushKind != "silent",
              let envelopeId = envelopeId, !envelopeId.isEmpty,
              let sealedB64 = sealedB64,
              let sealedData = Data(base64Encoded: sealedB64) else {
            // Record WHY we didn't even try, so "no receipt" is distinguishable
            // from "the receipt failed". A push with no inlined sealed blob is
            // the expected case for a message over the FCM size budget.
            NseReceiptLog.record(stage: "nopayload", http: nil, note: pushKind)
            finish(content)
            return
        }

        SealedReceiptSender.send(
            deliveredEnvelopeId: envelopeId,
            sealedBlob: [UInt8](sealedData)
        ) { [weak self] outcome in
            // Always record: this is the only way to see which stage a store
            // build reached (no console, and every failure is silent by design).
            NseReceiptLog.record(stage: outcome.stage, http: outcome.http, note: outcome.note)
            if NanbNotificationService.debugBanner {
                // Prefer the HTTP code; fall back to the failure note (e.g. a
                // URLError code for a POST that got no response), else "-".
                let code = outcome.http.map(String.init) ?? (outcome.note ?? "-")
                content.body = "New message ·\(outcome.stage)·\(code)"
            }
            self?.finish(content)
        }
    }

    private func finish(_ content: UNNotificationContent) {
        contentHandler?(content)
        contentHandler = nil
    }

    override func serviceExtensionTimeWillExpire() {
        // ~30 s budget about to expire — deliver the best we have.
        if let content = bestAttemptContent {
            finish(content)
        }
    }
}
