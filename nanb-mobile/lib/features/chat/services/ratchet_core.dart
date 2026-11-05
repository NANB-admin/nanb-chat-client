import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../../core/crypto/conversation_crypto_state.dart';
import '../../../core/crypto/crypto_bridge.dart';
import '../../../core/db/app_database.dart';
import '../../../core/models/envelope.dart' as wire;
import '../../../core/network/api_client.dart';
import '../../../core/push/push_kind.dart';
import '../models/conversation.dart';

/// The v1 (pre-MLS) ratchet crypto primitive shared by BOTH the send and
/// receive paths: load/init per-(conversation, device) ratchet state, encrypt a
/// single-peer message, and run the multi-device ratchet fan-out. The notifier's
/// send orchestration (_sendOptimistic / _sendControlMessage / _sendSelfControl)
/// and receive orchestration (_ratchetStateForSender / _tryRecoverRatchet) call
/// into this. The device caches that resolve fan-out targets (peer/own device
/// lists, X25519 lookup, warming) stay in the notifier — they're cross-cutting
/// (also used by SealedSender, reactions, receipts). Extracted from
/// `ConversationsNotifier`.
class RatchetCore {
  RatchetCore({
    required CryptoBridge crypto,
    required ApiClient api,
    required AppDatabase db,
    required int? Function() contentTtlSeconds,
  })  : _crypto = crypto,
        _api = api,
        _db = db,
        _contentTtlSeconds = contentTtlSeconds;

  final CryptoBridge _crypto;
  final ApiClient _api;
  final AppDatabase _db;
  final int? Function() _contentTtlSeconds;

  /// Load the '' (primary-peer) ratchet for [convo], initialising it from the
  /// peer's X25519 if absent. Null when no peer key is available.
  Future<ConversationCryptoState?> loadOrInitCryptoState(
      Conversation convo) async {
    final loaded = await _db.loadConversationCryptoState(convo.id);
    if (loaded != null) return loaded;
    if (convo.peerX25519PubKey.isEmpty) return null;
    final initial = await _crypto.initConversationCrypto(
      conversationId: convo.id,
      peerX25519PubKey: convo.peerX25519PubKey,
    );
    await _db.saveConversationCryptoState(initial);
    return initial;
  }

  /// Load the device-keyed ratchet for ([conversationId], [ratchetKey]),
  /// initialising it from [x25519] if absent. Null when [x25519] is empty.
  Future<ConversationCryptoState?> loadOrInitDeviceRatchet({
    required String conversationId,
    required String ratchetKey,
    required List<int> x25519,
  }) async {
    final loaded = await _db.loadConversationCryptoState(conversationId,
        peerDeviceId: ratchetKey);
    if (loaded != null) return loaded;
    if (x25519.isEmpty) return null;
    final initial = (await _crypto.initConversationCrypto(
      conversationId: conversationId,
      peerX25519PubKey: x25519,
    ))
        .copyWith(peerDeviceId: ratchetKey);
    await _db.saveConversationCryptoState(initial);
    return initial;
  }

  /// Encrypt [plaintext] for [convo]'s primary ratchet; [onStateAdvanced]
  /// receives the advanced state (the caller persists it after the send acks).
  Future<List<int>> encryptForConvo(
    Conversation convo,
    List<int> plaintext, {
    required void Function(ConversationCryptoState) onStateAdvanced,
  }) async {
    final cryptoState = await loadOrInitCryptoState(convo);
    if (cryptoState == null) {
      throw StateError('crypto: no peer key for conversation ${convo.id}');
    }
    final encrypted = await _crypto.encryptMessage(
      state: cryptoState,
      plaintext: plaintext,
    );
    onStateAdvanced(encrypted.newState);
    return encrypted.ciphertext;
  }

  /// Multi-device 1:1 ratchet fan-out: encrypts [wireBody] separately for each
  /// target device (its own ratchet) and submits a text_legacy envelope to each.
  /// Returns the first successful submit; each device's ratchet advances +
  /// persists on its own ack. Best-effort per device (only throws if ALL fail).
  ///
  /// [pushKind] shapes the offline wakeup: null (default) for a normal content
  /// fan-out that should wake the peer; `PushKind.silent` when fanning a
  /// control event to my own devices, so it never raises a banner.
  Future<SubmitMessageResult> fanout(
    String conversationId,
    String wireBody,
    List<RatchetFanoutTarget> targets, {
    String? pushKind,
    String? selfAccountId,
  }) async {
    final plaintext = utf8.encode(wireBody);
    SubmitMessageResult? firstOk;
    Object? firstError;
    for (final t in targets) {
      try {
        final state = await loadOrInitDeviceRatchet(
          conversationId: conversationId,
          ratchetKey: t.ratchetKey,
          x25519: t.x25519,
        );
        if (state == null) {
          firstError ??= StateError('no ratchet for device ${t.deviceId}');
          continue;
        }
        final enc =
            await _crypto.encryptMessage(state: state, plaintext: plaintext);
        final r = await _api.submitMessage(SubmitMessagePayload(
          conversationId: conversationId,
          envelopeType: wire.EnvelopeType.textLegacy,
          recipientAccountId: t.accountId,
          recipientDeviceId: t.deviceId,
          ciphertext: enc.ciphertext,
          ttlSeconds: _contentTtlSeconds(),
          // A copy to the sender's OWN other device is silent (no banner there).
          pushKind: pushKindForRecipient(
              recipientAccountId: t.accountId,
              selfAccountId: selfAccountId,
              requested: pushKind),
        ));
        // Persist the advanced ratchet only after the server acked the slot.
        await _db.saveConversationCryptoState(enc.newState);
        firstOk ??= r;
      } catch (e) {
        firstError ??= e;
        debugPrint('multi-device fanout to ${t.deviceId} failed: $e');
      }
    }
    if (firstOk == null) throw firstError ?? StateError('fanout: no targets');
    return firstOk;
  }
}

/// A single fan-out recipient for [RatchetCore.fanout].
class RatchetFanoutTarget {
  const RatchetFanoutTarget({
    required this.accountId,
    required this.deviceId,
    required this.ratchetKey,
    required this.x25519,
  });

  final String accountId;
  final String deviceId;

  /// Storage key for this pair's ratchet: '' for the peer's primary device
  /// (single-device baseline), else the device id.
  final String ratchetKey;
  final List<int> x25519;
}
