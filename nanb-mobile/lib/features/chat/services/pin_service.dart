import 'dart:async';

import '../models/message_control.dart';
import 'notifier_service_host.dart';

/// Owns the conversation's single shared pinned message: set/clear it (applied
/// locally, fanned to the peer, and self-synced to our own devices) and apply
/// inbound pin controls. One pin per chat, last-write-wins; any participant may
/// change it. Extracted from `ConversationsNotifier`.
class PinService {
  PinService(this._host);

  final NotifierServiceHost _host;

  /// Set the conversation's pinned message to [envelopeId], or clear it when
  /// null. No-op if unchanged. On a real change, fans a `MessageControl.pin`
  /// to the peer + our own devices.
  Future<void> setPin(String conversationId, String? envelopeId) async {
    final live = _host.conversation(conversationId);
    if (live == null) return;
    final previous = live.pinnedEnvelopeId;
    final changed = await _host.runLocked(
        conversationId, () => applyLocked(conversationId, envelopeId));
    if (changed != true) return;
    // On a clear, the control names the id being removed so a peer/sibling only
    // clears if it still matches; on a set, the new id.
    final control = MessageControl.pin(
      targetEnvelopeId: envelopeId ?? previous ?? '',
      remove: envelopeId == null,
    ).encode();
    unawaited(_host.sendControl(conversationId, control));
    unawaited(_host.sendSelfControl(conversationId, control));
  }

  /// Apply a pin set/clear to the live conversation, persist, and notify;
  /// returns true iff it actually changed. The CALLER MUST HOLD the
  /// conversation lock (invoked under `runLocked` from [setPin] and inline from
  /// the notifier's already-locked control-apply path).
  Future<bool> applyLocked(String conversationId, String? envelopeId) async {
    final live = _host.conversation(conversationId);
    if (live == null) return false;
    if (live.pinnedEnvelopeId == envelopeId) return false;
    final updated = live.copyWith(pinnedEnvelopeId: envelopeId);
    _host.setConversation(conversationId, updated);
    await _host.db.upsertConversation(updated);
    _host.notifyHost();
    return true;
  }
}
