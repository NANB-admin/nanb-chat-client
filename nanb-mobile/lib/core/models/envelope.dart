import 'package:flutter/foundation.dart';

import 'json_bytes.dart';

class EnvelopeType {
  EnvelopeType._();
  static const String mlsApplication = 'mls_application';
  static const String mlsHandshake = 'mls_handshake';
  static const String mlsWelcome = 'mls_welcome';
  static const String textLegacy = 'text_legacy';
  static const String keyPackagePublish = 'key_package_publish';
  static const String mediaEnvelope = 'media_envelope';

  /// Sealed-sender (Phase 1) outer wrapper. The `ciphertext` is an opaque
  /// per-recipient sealed blob (see `core/crypto/sealed_envelope.dart`); the
  /// recipient opens it to recover the real inner envelope (type, conversation,
  /// sender, ciphertext) and dispatches that. The server stores only this opaque
  /// type + the recipient device — no group_id, sender, or conversation.
  static const String sealed = 'sealed';

  /// Ephemeral typing signal relayed over the WS, never persisted. Ciphertext
  /// is a single byte: 1 = typing, 0 = stopped.
  static const String typing = 'typing';

  /// Ephemeral, server-originated transport "delivered" signal: a recipient
  /// device confirmed our pushed envelope physically landed (before it opened
  /// the app). Never persisted. Ciphertext is the UTF-8 envelope id that was
  /// delivered, so the sender matches it to its outgoing message.
  static const String deliveryStatus = 'delivery_status';

  /// Ephemeral, server-originated signal: one of THIS account's devices was just
  /// linked. Carries no content or envelope id (never persisted, never acked).
  /// The receiving device re-runs the own-device reconcile so the newcomer is
  /// added to existing MLS 1:1 groups now rather than at the next reconnect.
  static const String devicesChanged = 'devices_changed';

  /// INNER type (only ever seen after unsealing a [sealed] envelope, never on
  /// the wire as an outer type). A recipient's FCM background isolate sends this
  /// back to the original sender when a sealed message arrives while the app is
  /// closed: a transport "delivered" the server can't relay itself (sealed
  /// sender hides who the sender is). Unlike a normal receipt it is NOT
  /// E2EE/MLS-encrypted (the bg isolate must not advance the ratchet) — its
  /// payload is an Ed25519-signed [DeliveredReceipt] the sender verifies. See
  /// `core/crypto/delivered_receipt.dart`.
  static const String deliveredReceipt = 'delivered_receipt';

  /// A device that lost a group asking to be re-added, or to be sent what it
  /// missed. Inner type of a sealed envelope; see `GroupRecoveryMessage`.
  static const String groupRecovery = 'group_recovery';
}

@immutable
class Envelope {
  const Envelope({
    required this.envelopeId,
    required this.version,
    required this.domain,
    required this.envelopeType,
    required this.conversationId,
    required this.senderDeviceId,
    required this.recipientAccountId,
    required this.recipientDeviceId,
    required this.ciphertext,
    required this.serverTs,
  });

  final String envelopeId;
  final String version;
  final String domain;
  final String envelopeType;
  final String conversationId;
  final String senderDeviceId;
  final String recipientAccountId;
  final String recipientDeviceId;
  final List<int> ciphertext;
  final DateTime serverTs;

  /// Returns a copy with [senderDeviceId] replaced. Used on the MLS receive
  /// path to substitute the cryptographically-authenticated sender (the MLS
  /// credential's client id) for the server-assigned transport value, so every
  /// downstream use — the stored message, `mine`/self-sync detection, and
  /// control-message authorisation — keys off the verified sender rather than a
  /// field the server stamped. Sealed-sender Phase 0; also a hardening, since
  /// the transport `sender_device_id` is server-asserted, not authenticated.
  Envelope withSenderDeviceId(String value) => Envelope(
        envelopeId: envelopeId,
        version: version,
        domain: domain,
        envelopeType: envelopeType,
        conversationId: conversationId,
        senderDeviceId: value,
        recipientAccountId: recipientAccountId,
        recipientDeviceId: recipientDeviceId,
        ciphertext: ciphertext,
        serverTs: serverTs,
      );

  factory Envelope.fromJson(Map<String, dynamic> json) => Envelope(
        envelopeId: json['envelope_id'] as String,
        version: json['version'] as String,
        domain: json['domain'] as String,
        envelopeType: json['envelope_type'] as String,
        conversationId: json['conversation_id'] as String,
        senderDeviceId: json['sender_device_id'] as String,
        recipientAccountId: json['recipient_account_id'] as String,
        recipientDeviceId: json['recipient_device_id'] as String,
        ciphertext: bytesFromJson(json['ciphertext']),
        serverTs: DateTime.parse(json['server_ts'] as String),
      );

  Map<String, dynamic> toJson() => {
        'envelope_id': envelopeId,
        'version': version,
        'domain': domain,
        'envelope_type': envelopeType,
        'conversation_id': conversationId,
        'sender_device_id': senderDeviceId,
        'recipient_account_id': recipientAccountId,
        'recipient_device_id': recipientDeviceId,
        'ciphertext': ciphertext,
        'server_ts': serverTs.toUtc().toIso8601String(),
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Envelope &&
          envelopeId == other.envelopeId &&
          version == other.version &&
          domain == other.domain &&
          envelopeType == other.envelopeType &&
          conversationId == other.conversationId &&
          senderDeviceId == other.senderDeviceId &&
          recipientAccountId == other.recipientAccountId &&
          recipientDeviceId == other.recipientDeviceId &&
          listEquals(ciphertext, other.ciphertext) &&
          serverTs == other.serverTs;

  @override
  int get hashCode => Object.hash(
        envelopeId,
        version,
        domain,
        envelopeType,
        conversationId,
        senderDeviceId,
        recipientAccountId,
        recipientDeviceId,
        Object.hashAll(ciphertext),
        serverTs,
      );
}
