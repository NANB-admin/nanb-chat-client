import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// A transport-level "delivered" acknowledgement the RECIPIENT sends back to
/// the original sender from its FCM background isolate, when a sealed message
/// arrives while the app is closed.
///
/// It rides as the inner payload of a `sealed` envelope
/// (`EnvelopeType.deliveredReceipt`) addressed to the sender's device, so the
/// server stays blind (sealed sender). Unlike a normal receipt it is NOT
/// E2EE/MLS-encrypted: the background isolate must never advance the
/// forward-secret ratchet (that would lose the message for the foreground).
/// Instead the recipient **Ed25519-signs** it with its account identity key, so
/// the sender can verify it is authentic and unforgeable — anyone who lacked the
/// recipient's identity private key could not mint a valid "delivered".
///
/// The signature is over [signingBytes], which binds the ack to the exact
/// envelope + conversation, so a captured signature can't be replayed to flip
/// the status of a different message.
class DeliveredReceipt {
  const DeliveredReceipt({
    required this.deliveredEnvelopeId,
    required this.conversationId,
    required this.signature,
  });

  /// The envelope id (the original outer/sealed envelope) being acknowledged —
  /// what the sender's outbox keys its delivery status on.
  final String deliveredEnvelopeId;

  /// The sender's conversation id (echoed from the original message's inner
  /// record), so the sender's `_applyReceipt` targets the right thread even if
  /// conversation ids weren't canonical across the two devices.
  final String conversationId;

  /// Ed25519 signature over [signingBytes], by the recipient's identity key.
  final List<int> signature;

  /// Domain-separated bytes signed by the recipient / verified by the sender.
  static List<int> signingBytes(
          String conversationId, String deliveredEnvelopeId) =>
      utf8.encode(
          'nanb-delivered-receipt-v1 $conversationId $deliveredEnvelopeId');

  Uint8List encode() => Uint8List.fromList(utf8.encode(jsonEncode({
        'env': deliveredEnvelopeId,
        'conv': conversationId,
        'sig': base64.encode(signature),
      })));

  static DeliveredReceipt? tryDecode(List<int> bytes) {
    Object? raw;
    try {
      raw = jsonDecode(utf8.decode(bytes));
    } catch (_) {
      return null;
    }
    if (raw is! Map) return null;
    final env = raw['env'];
    final conv = raw['conv'];
    final sig = raw['sig'];
    if (env is! String || env.isEmpty) return null;
    if (conv is! String || conv.isEmpty) return null;
    if (sig is! String || sig.isEmpty) return null;
    final List<int> sigBytes;
    try {
      sigBytes = base64.decode(sig);
    } catch (_) {
      return null;
    }
    if (sigBytes.isEmpty) return null;
    return DeliveredReceipt(
      deliveredEnvelopeId: env,
      conversationId: conv,
      signature: sigBytes,
    );
  }

  /// Verifies [signature] against the recipient's Ed25519 identity public key
  /// ([signerIdentityPubKey], 32 raw bytes). Returns false on any malformed
  /// input rather than throwing, so a bad receipt is simply ignored.
  Future<bool> verify(List<int> signerIdentityPubKey) async {
    if (signerIdentityPubKey.length != 32 || signature.isEmpty) return false;
    try {
      return await Ed25519().verify(
        signingBytes(conversationId, deliveredEnvelopeId),
        signature: Signature(
          signature,
          publicKey:
              SimplePublicKey(signerIdentityPubKey, type: KeyPairType.ed25519),
        ),
      );
    } catch (_) {
      return false;
    }
  }
}
