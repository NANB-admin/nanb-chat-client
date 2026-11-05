import 'dart:async';

import '../models/chat_message.dart';
import '../models/message_control.dart';
import '../models/message_kind.dart';
import 'notifier_service_host.dart';

/// Keeps "Delete for me" in step across THIS account's own devices.
///
/// The user-facing action removes the message here, then tells the account's
/// OTHER devices (and only them — never the peer or the group, since "for me"
/// must not delete anything for anyone else) to drop it too. The inbound side
/// honors the control only from one of our own devices and performs a plain
/// local delete WITHOUT re-broadcasting, so the sync cannot echo.
///
/// The local delete itself stays in `ConversationsNotifier.deleteMessageLocal`,
/// which other internal callers (disappearing sweep, expiry, outbox cleanup,
/// the unsend receiver) share; only this entry point broadcasts.
class DeleteSyncService {
  DeleteSyncService(
    this._host, {
    required Future<void> Function(String conversationId, ChatMessage message)
        deleteMessageLocal,
  }) : _deleteMessageLocal = deleteMessageLocal;

  final NotifierServiceHost _host;
  final Future<void> Function(String, ChatMessage) _deleteMessageLocal;

  /// The user chose "Delete for me": delete [message] here, then self-sync the
  /// deletion to our own other devices (detached — never blocks the UI).
  Future<void> deleteForMe(String conversationId, ChatMessage message) async {
    await _deleteMessageLocal(conversationId, message);
    if (!_siblingsCanHaveIt(message)) return;
    unawaited(_host
        .sendSelfControl(
          conversationId,
          MessageControl.deleteForMe(message.envelopeId).encode(),
        )
        .catchError((_) {/* best-effort; the local delete already happened */}));
  }

  /// Applies an inbound delete-for-me. Honored ONLY when the sending device is
  /// one of OUR OWN, and only for a message in THIS conversation. Idempotent: a
  /// message we no longer have is a no-op. Runs inside the conversation's lock,
  /// so it takes none and sends nothing.
  Future<void> applyInbound({
    required String conversationId,
    required MessageControl control,
    required String senderDeviceId,
    required String myDeviceId,
  }) async {
    if (!control.isDeleteForMe) return;
    if (!await _host.isMyDeviceWarm(senderDeviceId, myDeviceId)) return;
    final live = _host.conversation(conversationId);
    if (live == null) return;
    final id = control.targetEnvelopeId;
    for (final m in live.messages) {
      if (m.envelopeId == id) {
        await _deleteMessageLocal(conversationId, m);
        return;
      }
    }
    // Outside the in-memory window: delete the stored row, but only if it
    // belongs to this conversation (the id alone must not reach across chats).
    final stored = await _host.db.getMessage(id);
    if (stored == null || stored.conversationId != conversationId) return;
    await _deleteMessageLocal(conversationId, stored);
  }

  /// Messages that never reached the server (still in the outbox) and local-only
  /// system lines have no counterpart on a sibling device.
  bool _siblingsCanHaveIt(ChatMessage m) {
    if (m.kind == MessageKind.system) return false;
    final outbox = m.outboxId;
    return outbox == null || outbox.isEmpty;
  }
}
