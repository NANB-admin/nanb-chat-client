import '../models/chat_background_override.dart';
import '../models/chat_message.dart';
import '../models/conversation_state_field.dart';
import '../models/message_control.dart';
import '../models/message_kind.dart';
import '../models/state_field_change.dart';
import 'conversation_settings_service.dart';
import 'conversation_state_store.dart';
import 'notifier_service_host.dart';

/// Applies an inbound `conversation_state` control from one of OUR OWN other
/// devices. Each field converges last-writer-wins on its own
/// (timestampMs, deviceId) version. It uses the NON-broadcasting setters of
/// [ConversationSettingsService], so applying can never echo back.
class ConversationStateApplier {
  ConversationStateApplier(
    this._host, {
    required ConversationSettingsService settings,
    required ConversationStateStore store,
    required Future<void> Function(String conversationId, ChatMessage message)
        deleteMessageLocal,
  })  : _settings = settings,
        _store = store,
        _deleteMessageLocal = deleteMessageLocal;

  final NotifierServiceHost _host;
  final ConversationSettingsService _settings;
  final ConversationStateStore _store;
  final Future<void> Function(String, ChatMessage) _deleteMessageLocal;

  /// Page size when sweeping older, not-in-memory rows for a clear.
  static const int _clearPage = 200;

  Future<void> applyInbound({
    required String conversationId,
    required MessageControl control,
    required String senderDeviceId,
    required String myDeviceId,
  }) async {
    final update = control.stateUpdate;
    if (update == null) return;
    if (!await _host.isMyDeviceWarm(senderDeviceId, myDeviceId)) return;
    if (_host.conversation(conversationId) == null) return;
    await _store.load();
    for (final field in ConversationStateField.values) {
      final change = update.changes[field];
      if (change == null) continue;
      if (!change.version.isNewerThan(_store.versionOf(conversationId, field))) {
        continue;
      }
      final watermark = await _apply(conversationId, field, change);
      if (watermark == null) continue; // invalid value: ignore, keep old version
      await _store.recordVersion(conversationId, field, change.version,
          watermark: watermark >= 0 ? watermark : null);
    }
  }

  /// Applies one field. Returns -1 for "applied, no watermark", the new
  /// watermark for the two monotone fields, or null if the value was invalid.
  Future<int?> _apply(String id, ConversationStateField field,
      StateFieldChange change) async {
    switch (field) {
      case ConversationStateField.muted:
        await _settings.setMuted(id, change.flag!);
      case ConversationStateField.pinned:
        await _settings.setPinned(id, change.flag!);
      case ConversationStateField.archived:
        await _settings.setArchived(id, change.flag!);
      case ConversationStateField.blocked:
        await _settings.setBlocked(id, change.flag!);
      case ConversationStateField.verified:
        await _settings.setVerified(id, change.flag!);
      case ConversationStateField.disappearingTtl:
        final ttl = change.number!;
        if (ttl != -1 && ttl <= 0) return null;
        await _settings.setDisappearingTtl(id, ttl);
      case ConversationStateField.background:
        final value = ChatBackgroundOverride.fromSyncWire(change.text!);
        if (value == null) return null;
        await _store.setBackground(id, value);
        _host.notifyHost();
      case ConversationStateField.readUpToMs:
        final merged = _max(_store.watermarkOf(id, field), change.number!);
        await _applyRead(id, merged);
        return merged;
      case ConversationStateField.clearedAtMs:
        final merged = _max(_store.watermarkOf(id, field), change.number!);
        await _applyClear(id, merged);
        return merged;
    }
    return -1;
  }

  int _max(int a, int b) => a > b ? a : b;

  bool _isUnreadCandidate(ChatMessage m, int upToMs) =>
      !m.mine &&
      m.kind != MessageKind.system &&
      m.serverTs.millisecondsSinceEpoch > upToMs;

  /// Clears unread for messages read on a sibling: the new count is the number
  /// of loaded incoming messages newer than [upToMs], and never exceeds the
  /// current count.
  Future<void> _applyRead(String id, int upToMs) async {
    final live = _host.conversation(id);
    if (live == null) return;
    final remaining =
        live.messages.where((m) => _isUnreadCandidate(m, upToMs)).length;
    final next = remaining < live.unreadCount ? remaining : live.unreadCount;
    if (next == live.unreadCount) return;
    final updated = live.copyWith(unreadCount: next);
    _host.setConversation(id, updated);
    await _host.db.upsertConversation(updated);
    _host.notifyHost();
  }

  /// Deletes every local message with serverTs <= [upToMs] (with the same
  /// artifact cleanup as any local delete), including rows outside the
  /// in-memory window, WITHOUT re-broadcasting.
  Future<void> _applyClear(String id, int upToMs) async {
    final live = _host.conversation(id);
    if (live == null) return;
    final done = <String>{};
    for (final m in live.messages
        .where((m) => m.serverTs.millisecondsSinceEpoch <= upToMs)
        .toList()) {
      done.add(m.envelopeId);
      await _deleteMessageLocal(id, m);
    }
    for (var i = 0; i < 1000; i++) {
      final List<ChatMessage> page;
      try {
        page = await _host.db
            .loadMessages(id, limit: _clearPage, beforeServerTsMs: upToMs + 1);
      } catch (_) {
        break;
      }
      final fresh = page.where((m) => !done.contains(m.envelopeId)).toList();
      if (fresh.isEmpty) break;
      for (final m in fresh) {
        done.add(m.envelopeId);
        await _deleteMessageLocal(id, m);
      }
    }
    final after = _host.conversation(id);
    if (after == null) return;
    final remaining =
        after.messages.where((m) => _isUnreadCandidate(m, 0)).length;
    final updated = after.copyWith(
      unreadCount:
          remaining < after.unreadCount ? remaining : after.unreadCount,
      hasMoreOlderMessages: false,
    );
    _host.setConversation(id, updated);
    await _host.db.upsertConversation(updated);
    _host.notifyHost();
  }
}
