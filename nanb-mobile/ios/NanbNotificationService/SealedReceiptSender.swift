import Foundation

/// Builds and sends the sealed, Ed25519-signed "delivered" receipt for a sealed
/// message that arrived while the app was closed — the iOS counterpart of Dart's
/// `sendSealedDeliveredReceipt` (`lib/core/push/sealed_delivered_receipt.dart`),
/// driven natively from the Notification Service Extension because iOS shows a
/// visible alert without running any Dart isolate.
///
/// It opens ONLY the OUTER seal (a static X25519 unwrap that does NOT advance the
/// forward-secret ratchet, so the foreground can still decrypt the message), then
/// deposits the receipt on the UNAUTHENTICATED sealed path (no JWT → the server
/// never sees this device's identity). Best-effort: every failure returns a short
/// stage tag for diagnostics; the end-to-end receipt on next foreground is the
/// durable backstop.
enum SealedReceiptSender {
    /// A coarse outcome surfaced (in debug builds) into the banner so a single
    /// on-device test pinpoints which step failed. `stage` is one of:
    /// skiptor / nox25519 / sealfail / innerempty / blocked / nopeerkeys /
    /// noidentity / signfail / sealoutfail / neturl / sent. `http` is the POST
    /// status code.
    struct Outcome { let stage: String; let http: Int?; var note: String? = nil }

    // App Group keys, mirrored from SecureStorage by the app (must match
    // IosSharedStore.mirroredKeys on the Dart side).
    private static let kX25519Priv = "crypto.identity.x25519_priv.b64"
    private static let kIdentitySeed = "crypto.identity.seed.b64"
    private static let kPeerSealKeys = "delivery.peer_seal_keys"
    private static let kBlockedConvos = "push.blocked_convos"
    private static let kServerUrl = "pref.server_url"
    private static let kBuiltInTor = "pref.built_in_tor_enabled"

    /// Runs the receipt flow. Synchronous crypto, async network; [completion]
    /// fires exactly once with the outcome.
    static func send(deliveredEnvelopeId: String,
                     sealedBlob: [UInt8],
                     completion: @escaping (Outcome) -> Void) {
        // Fail CLOSED under built-in Tor: the extension has no Tor transport (the
        // embedded engine runs only in the foreground app), so a clearnet receipt
        // POST here would leak this device's real IP <-> account to the server —
        // defeating the anonymity the user opted into. Skip the receipt entirely
        // when Tor is on; it's deferred to the next foreground catchup over Tor.
        // Same posture as the Dart background isolate
        // (`ApiClientDio.createForBackgroundIsolate`). The wake banner is
        // unaffected — it's set by NanbNotificationService, not built here.
        if builtInTorEnabled() {
            return completion(Outcome(stage: "skiptor", http: nil))
        }
        guard let x25519Priv = NseSharedStore.base64Bytes(kX25519Priv) else {
            return completion(Outcome(stage: "nox25519", http: nil))
        }
        let opened: [UInt8]
        let inner: SealedInner
        do {
            opened = try SealedSenderCrypto.open(sealed: sealedBlob, recipientX25519Priv: x25519Priv)
            inner = try SealedInner.decode(opened)
        } catch {
            return completion(Outcome(stage: "sealfail", http: nil))
        }
        let senderDeviceId = inner.senderDeviceId
        let conversationId = inner.conversationId
        guard !senderDeviceId.isEmpty, !conversationId.isEmpty else {
            return completion(Outcome(stage: "innerempty", http: nil))
        }

        // A blocked conversation stays silent in BOTH directions — no receipt
        // (mirrors the foreground/Android rule). The banner can't be suppressed
        // on iOS, but at least the sender earns no "delivered".
        if blockedConversations().contains(conversationId) {
            return completion(Outcome(stage: "blocked", http: nil))
        }

        guard let peer = peerSealKeys(deviceId: senderDeviceId) else {
            return completion(Outcome(stage: "nopeerkeys", http: nil))
        }
        guard let seed = NseSharedStore.base64Bytes(kIdentitySeed) else {
            return completion(Outcome(stage: "noidentity", http: nil))
        }

        let receiptJson: [UInt8]
        let outerBlob: [UInt8]
        do {
            let sig = try DeliveredReceipt.sign(
                seed: seed, conversationId: conversationId, deliveredEnvelopeId: deliveredEnvelopeId)
            receiptJson = DeliveredReceipt.encode(
                deliveredEnvelopeId: deliveredEnvelopeId, conversationId: conversationId, signature: sig)
            // Wrap as an inner record (senderDeviceId stays empty: the receiver
            // authenticates via the signature, not this transport field) and seal
            // it to the sender device's X25519.
            let innerRecord = SealedInner(
                conversationId: conversationId,
                envelopeType: "delivered_receipt",
                senderDeviceId: "",
                ciphertext: receiptJson).encode()
            outerBlob = try SealedSenderCrypto.seal(plaintext: innerRecord, recipientX25519Pub: peer.x)
        } catch {
            return completion(Outcome(stage: "sealoutfail", http: nil))
        }

        guard let url = URL(string: baseUrl() + "/messages/sealed") else {
            return completion(Outcome(stage: "neturl", http: nil))
        }
        post(url: url, recipientDeviceId: senderDeviceId, ciphertext: outerBlob, accessKey: peer.u) { code, note in
            completion(Outcome(stage: "sent", http: code, note: note))
        }
    }

    // MARK: - Keychain-backed inputs

    private struct PeerKeys { let x: Data; let u: Data }

    private static func peerSealKeys(deviceId: String) -> PeerKeys? {
        guard let raw = NseSharedStore.string(kPeerSealKeys),
              let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dir = obj as? [String: Any],
              let entry = dir[deviceId] as? [String: Any],
              let xb64 = entry["x"] as? String, let ub64 = entry["u"] as? String,
              let x = Data(base64Encoded: xb64), let u = Data(base64Encoded: ub64),
              x.count == 32, !u.isEmpty else { return nil }
        return PeerKeys(x: x, u: u)
    }

    private static func blockedConversations() -> Set<String> {
        guard let raw = NseSharedStore.string(kBlockedConvos),
              let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let list = obj as? [String] else {
            return []
        }
        return Set(list)
    }

    private static func baseUrl() -> String {
        let s = NseSharedStore.string(kServerUrl) ?? "https://nanb.link"
        return s.hasSuffix("/") ? String(s.dropLast()) : s
    }

    /// Whether the user's built-in Tor pref is ON. Read from the App Group mirror
    /// the same way as every other value (`NseSharedStore.string`), where the app
    /// stores the Dart `builtInTorEnabled` bool as the string "true"/"false".
    /// Tor is OPT-IN and defaults OFF, so an ABSENT value counts as OFF and the
    /// clearnet receipt is permitted. Only an explicit "true" — the user turned
    /// Tor ON — suppresses it (the app has no Tor engine in this process, and a
    /// clearnet call would leak the IP ↔ account link the user opted into Tor to
    /// hide; the receipt is deferred to the foreground). Matches the Dart rule
    /// `getString(...) == 'true'` in `ApiClientDio.createForBackgroundIsolate`.
    private static func builtInTorEnabled() -> Bool {
        return NseSharedStore.string(kBuiltInTor) == "true"
    }

    // MARK: - Unauthenticated sealed submit

    private static func post(url: URL,
                             recipientDeviceId: String,
                             ciphertext: [UInt8],
                             accessKey: Data,
                             completion: @escaping (Int?, String?) -> Void) {
        // Byte fields ride as JSON int arrays (matches the Dart List<int> the Go
        // decoder accepts as []byte). UNAUTHENTICATED — no bearer token.
        let body: [String: Any] = [
            "conversation_id": "",
            "envelope_type": "sealed",
            "recipient_account_id": "",
            "recipient_device_id": recipientDeviceId,
            "ciphertext": ciphertext.map { Int($0) },
            "access_key": [UInt8](accessKey).map { Int($0) },
            // Protocol-only: keeps the server from pushing the original sender a
            // phantom "New message" banner for this delivery receipt.
            "push_kind": "silent",
        ]
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else {
            return completion(nil, "encode")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = payload
        req.timeoutInterval = 8
        URLSession.shared.dataTask(with: req) { _, response, error in
            if let code = (response as? HTTPURLResponse)?.statusCode {
                completion(code, nil)
            } else {
                // No HTTP response (DNS/TLS/timeout/blocked): surface the URLError
                // code so the banner shows WHY, e.g. "url-1009" (offline),
                // "url-1003" (host not found), "url-1004" (cannot connect).
                let note = (error as? URLError).map { "url\($0.errorCode)" } ?? "noresp"
                completion(nil, note)
            }
        }.resume()
    }
}
