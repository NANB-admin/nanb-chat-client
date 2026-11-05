import Foundation
import CryptoKit

/// Swift port of `nanb-mobile/lib/core/crypto/delivered_receipt.dart`.
///
/// A transport-level "delivered" ack the recipient sends back to the original
/// sender of a sealed message that arrived while the app was closed. It is NOT
/// E2EE/MLS-encrypted (the background must never advance the forward-secret
/// ratchet); instead it is Ed25519-signed with the account identity key so the
/// sender can verify authenticity. The signature binds the ack to the exact
/// conversation + envelope, so it can't be replayed onto another message.
enum DeliveredReceipt {
    /// Domain-separated bytes signed by the recipient / verified by the sender.
    /// MUST match Dart's `DeliveredReceipt.signingBytes`.
    static func signingBytes(conversationId: String, deliveredEnvelopeId: String) -> Data {
        return Data("nanb-delivered-receipt-v1 \(conversationId) \(deliveredEnvelopeId)".utf8)
    }

    /// Ed25519-signs [signingBytes] with the 32-byte identity seed.
    static func sign(seed: Data, conversationId: String, deliveredEnvelopeId: String) throws -> Data {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        return try key.signature(for: signingBytes(
            conversationId: conversationId, deliveredEnvelopeId: deliveredEnvelopeId))
    }

    /// JSON encoding matching Dart's `encode()`: `{"env":..,"conv":..,"sig":<b64>}`.
    /// Key order is irrelevant — the peer parses by key.
    static func encode(deliveredEnvelopeId: String, conversationId: String, signature: Data) -> [UInt8] {
        let obj: [String: String] = [
            "env": deliveredEnvelopeId,
            "conv": conversationId,
            "sig": signature.base64EncodedString(),
        ]
        let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
        return [UInt8](data)
    }
}
