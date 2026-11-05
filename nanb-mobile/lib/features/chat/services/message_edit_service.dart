import 'dart:async';

import '../models/chat_message.dart';
import '../models/message_control.dart';
import '../models/message_kind.dart';
import 'notifier_service_host.dart';

/// Owns editing the text of a message you already sent: applies the edit on this
/// device, shares it as an encrypted `edit` control (to the peer and to your own
/// other devices), and applies such controls from others.
///
/// Only the author can edit, only text messages, and only for [editWindow] after
/// sending. The receiver cannot see the time limit (clocks differ), so it
/// enforces only authorship — the window is a sender-side courtesy.
class MessageEditService {
  MessageEditService(this._host);

  final NotifierServiceHost _host;

  /// How long after sending a message may still be edited.
  static const editWindow = Duration(minutes: 15);

  /// Whether [m] can be edited right now.
  static bool canEdit(ChatMessage m, {DateTime? now}) {
    if (!m.mine || m.kind != MessageKind.text) return false;
    if (m.failed || m.uploading || m.envelopeId.isEmpty) return false;
    if (m.outboxId != null && m.outboxId!.isNotEmpty) return false; // unsent
    final age = (now ?? DateTime.now().toUtc()).difference(m.serverTs.toUtc());
    return age <= editWindow;
  }

  /// Replaces the text of [target] (one of our own messages) with [newText] and
  /// tells the conversation. Returns the updated message, or null when the edit
  /// isn't allowed or changes nothing.
  Future<ChatMessage?> edit({
    required String conversationId,
    required ChatMessage target,
    required String newText,
  }) async {
    final text = newText.trim();
    if (text.isEmpty || text == target.body) return null;
    if (!canEdit(target)) return null;

    ChatMessage? updated;
    await _host.runLocked(conversationId, () async {
      updated = await _applyLocked(conversationId, target.envelopeId, text);
    });
    if (updated == null) return null;

    final control = MessageControl.edit(
      targetEnvelopeId: target.envelopeId,
      text: text,
    ).encode();
    // Peer (relayed to the peer's devices) + our own other devices.
    unawaited(_host.sendControl(conversationId, control));
    unawaited(_host.sendSelfControl(conversationId, control));
    return updated;
  }

  /// Applies an inbound edit [control]. The CALLER MUST HOLD the conversation
  /// lock (this runs on the already-locked decrypt path).
  ///
  /// Accepted only from the message's author — otherwise any participant could
  /// rewrite what someone else appears to have said.
  Future<void> applyInbound({
    required String conversationId,
    required MessageControl control,
    required String senderDeviceId,
    required String myDeviceId,
  }) async {
    final text = control.editedText;
    if (text == null) return;
    final target = await _find(conversationId, control.targetEnvelopeId);
    if (target == null || target.kind != MessageKind.text) return;

    final senderIsMe = await _host.isMyDeviceWarm(senderDeviceId, myDeviceId);
    if (senderIsMe != target.mine) return; // not the author's side
    if (!senderIsMe && target.senderDeviceId != senderDeviceId) return;

    await _applyLocked(conversationId, target.envelopeId, text);
  }

  Future<ChatMessage?> _find(String conversationId, String envelopeId) async {
    final live = _host.conversation(conversationId);
    if (live != null) {
      for (final m in live.messages) {
        if (m.envelopeId == envelopeId) return m;
      }
    }
    return _host.db.getMessage(envelopeId);
  }

  /// Stores [text] on the message (dropping its link card, which described the
  /// old text) and notifies. The caller must hold the conversation lock.
  Future<ChatMessage?> _applyLocked(
    String conversationId,
    String envelopeId,
    String text,
  ) async {
    final live = _host.conversation(conversationId);
    final idx =
        live?.messages.indexWhere((m) => m.envelopeId == envelopeId) ?? -1;
    if (live == null || idx < 0) {
      // Not in the loaded window — update the stored row so the new text shows
      // when it is next loaded.
      final stored = await _host.db.getMessage(envelopeId);
      if (stored == null) return null;
      final edited = stored.copyWith(
        body: text,
        edited: true,
        clearLinkPreview: true,
      );
      await _host.db.upsertMessages(conversationId, [edited]);
      return edited;
    }
    final updated = live.messages[idx].copyWith(
      body: text,
      edited: true,
      clearLinkPreview: true,
    );
    final messages = [...live.messages]..[idx] = updated;
    _host.setConversation(conversationId, live.copyWith(messages: messages));
    await _host.db.upsertMessages(conversationId, [updated]);
    _host.notifyHost();
    return updated;
  }
}
