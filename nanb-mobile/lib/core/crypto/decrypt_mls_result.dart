import 'package:flutter/foundation.dart';

/// Result of decrypting an MLS envelope with structured side-state.
///
/// [plaintext] is the application-message bytes, or null when the envelope
/// was a Commit / proposal (no user data to render).
///
/// [selfRemoved] is true when processing the envelope removed this device
/// from the group — the conversation is now gone from CoreCrypto's store.
/// Callers should disable the composer and inject a local
/// "you were removed" system line (spec §10.6).
///
/// [newEpoch] is the post-decrypt MLS epoch, or null when [selfRemoved]
/// is true (no epoch when the conversation no longer exists).
@immutable
class DecryptMlsResult {
  const DecryptMlsResult({
    required this.plaintext,
    required this.selfRemoved,
    required this.newEpoch,
    this.senderClientId,
  });
  final List<int>? plaintext;
  final bool selfRemoved;
  final int? newEpoch;

  /// The MLS-authenticated sender's client id (== the sender's device id, since
  /// each client is MLS-initialised with clientId = deviceId). Null for
  /// commits/proposals, or when the native bridge didn't surface it. Sealed
  /// sender (Phase 0): the receive path attributes the sender from this
  /// cryptographically-verified value rather than the server-assigned transport
  /// `sender_device_id`, so the transport field becomes removable.
  final String? senderClientId;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DecryptMlsResult &&
          listEquals(plaintext, other.plaintext) &&
          selfRemoved == other.selfRemoved &&
          newEpoch == other.newEpoch &&
          senderClientId == other.senderClientId;

  @override
  int get hashCode => Object.hash(
        plaintext == null ? 0 : Object.hashAll(plaintext!),
        selfRemoved,
        newEpoch,
        senderClientId,
      );
}
