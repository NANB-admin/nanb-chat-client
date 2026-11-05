import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'push_kind.dart';

/// Typed view over the FCM `data` map (or APNs payload) carried by a
/// wakeup push. Server-side: `push.DispatchWakeup` sets these keys
/// (spec §6.7).
@immutable
class WakeupPayload {
  const WakeupPayload({
    required this.envelopeId,
    required this.conversationId,
    this.pushKind,
    this.sealedPayload = const [],
  });
  final String envelopeId;
  final String conversationId;

  /// Non-encrypted push-style hint. `'call'` ⇒ ring (full-screen call
  /// notification) instead of a generic "new message". Null for normal wakeups.
  final String? pushKind;

  /// Sealed-sender only: the opaque OUTER sealed blob, inlined by the server
  /// when it fits the FCM budget. The background isolate opens it (a static
  /// X25519 unwrap — NO ratchet advance) to learn the sender and send a sealed
  /// closed-app "delivered" receipt without an identity-revealing fetch. Empty
  /// for non-sealed wakeups or when the blob was too large to inline.
  final List<int> sealedPayload;

  bool get isCall => pushKind == PushKind.call;

  /// A control/protocol-only wakeup (see [PushKind.silent]) — wakes the device
  /// for housekeeping but must not raise a visible "new message" banner.
  bool get isSilent => pushKind == PushKind.silent;

  static WakeupPayload? tryParse(Map<String, dynamic> data) {
    final env = data['envelope_id'];
    final conv = data['conversation_id'];
    if (env is! String || conv is! String) return null;
    var sealed = const <int>[];
    final rawSealed = data['sealed_payload'];
    if (rawSealed is String && rawSealed.isNotEmpty) {
      try {
        sealed = base64.decode(rawSealed);
      } catch (_) {/* malformed → treat as absent */}
    }
    return WakeupPayload(
      envelopeId: env,
      conversationId: conv,
      pushKind: data['push_kind'] is String ? data['push_kind'] as String : null,
      sealedPayload: sealed,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is WakeupPayload &&
          envelopeId == other.envelopeId &&
          conversationId == other.conversationId &&
          pushKind == other.pushKind &&
          listEquals(sealedPayload, other.sealedPayload);

  @override
  int get hashCode => Object.hash(
      envelopeId, conversationId, pushKind, Object.hashAll(sealedPayload));
}
