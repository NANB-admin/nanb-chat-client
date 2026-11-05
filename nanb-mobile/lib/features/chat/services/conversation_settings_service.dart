import 'dart:convert';

import '../../../core/secure_storage/secure_storage.dart';
import '../models/conversation.dart';
import 'notifier_service_host.dart';

/// Per-conversation LOCAL preferences: pin-to-top (chat-list), mute, archive,
/// block, and the disappearing-messages override. All local-only — the peer is
/// never told. The mute + block sets are mirrored into SecureStorage so the FCM
/// background isolate (no DB access) can suppress notifications. Extracted from
/// `ConversationsNotifier`.
class ConversationSettingsService {
  ConversationSettingsService({
    required NotifierServiceHost host,
    required SecureStorage secureStorage,
    required String mutedKey,
    required String blockedKey,
  })  : _host = host,
        _secureStorage = secureStorage,
        _mutedKey = mutedKey,
        _blockedKey = blockedKey;

  final NotifierServiceHost _host;
  final SecureStorage _secureStorage;
  final String _mutedKey;
  final String _blockedKey;

  /// Pins the conversation to the top of the chat list (local-only preference).
  Future<void> setPinned(String conversationId, bool pinned) =>
      _update(conversationId, (c) => c.copyWith(pinned: pinned));

  /// Mutes/unmutes (suppresses notifications for inbound messages); mirrors the
  /// muted set to SecureStorage for the background isolate.
  Future<void> setMuted(String conversationId, bool muted) async {
    await _update(conversationId, (c) => c.copyWith(muted: muted));
    await persistMutedSet();
  }

  /// Archives/unarchives (hides the conversation from the main list). A new
  /// inbound message un-archives it (handled in the envelope-append path).
  Future<void> setArchived(String conversationId, bool archived) =>
      _update(conversationId, (c) => c.copyWith(archived: archived));

  /// Blocks/unblocks a contact (hidden from both lists, composer replaced with
  /// an Unblock bar, inbound arrives silently). Local-only; the peer is not
  /// told. Mirrors the blocked set to SecureStorage for the background isolate.
  Future<void> setBlocked(String conversationId, bool blocked) async {
    await _update(conversationId, (c) => c.copyWith(blocked: blocked));
    await persistBlockedSet();
  }

  /// Marks the conversation verified/unverified (safety number confirmed).
  Future<void> setVerified(String conversationId, bool verified) async {
    final convo = _host.conversation(conversationId);
    if (convo == null || convo.verified == verified) return;
    await _update(conversationId, (c) => c.copyWith(verified: verified));
  }

  /// Sets the per-conversation disappearing-messages override. [ttlSeconds] of
  /// `-1` reverts to the global default; any value `> 0` makes every message
  /// sent here expire after that many seconds (rides the per-message `_ttl`
  /// header). No "off" — messages always expire.
  Future<void> setDisappearingTtl(String conversationId, int ttlSeconds) =>
      _update(
        conversationId,
        (c) => c.copyWith(disappearingTtl: ttlSeconds > 0 ? ttlSeconds : -1),
      );

  int disappearingTtlOf(String conversationId) =>
      _host.conversation(conversationId)?.disappearingTtl ?? -1;

  bool isMuted(String conversationId) =>
      _host.conversation(conversationId)?.muted ?? false;

  bool isBlocked(String conversationId) =>
      _host.conversation(conversationId)?.blocked ?? false;

  /// Mirrors the current muted conversation ids into SecureStorage. Best-effort;
  /// called on mute toggle + after hydration.
  Future<void> persistMutedSet() async {
    final ids = [
      for (final c in _host.allConversations())
        if (c.muted) c.id,
    ];
    try {
      await _secureStorage.putString(_mutedKey, jsonEncode(ids));
    } catch (_) {/* best-effort */}
  }

  /// Mirrors the current blocked conversation ids into SecureStorage.
  /// Best-effort; called on block toggle + after hydration.
  Future<void> persistBlockedSet() async {
    final ids = [
      for (final c in _host.allConversations())
        if (c.blocked) c.id,
    ];
    try {
      await _secureStorage.putString(_blockedKey, jsonEncode(ids));
    } catch (_) {/* best-effort */}
  }

  Future<void> _update(
    String conversationId,
    Conversation Function(Conversation) mutate,
  ) async {
    final convo = _host.conversation(conversationId);
    if (convo == null) return;
    final updated = mutate(convo);
    _host.setConversation(conversationId, updated);
    await _host.db.upsertConversation(updated);
    _host.notifyHost();
  }
}
