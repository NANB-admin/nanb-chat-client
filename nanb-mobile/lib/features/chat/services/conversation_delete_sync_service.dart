import 'dart:async';

import '../models/conversation_kind.dart';
import '../models/message_control.dart';
import 'notifier_service_host.dart';

/// Keeps "delete a 1:1 chat" in step across THIS account's own devices.
///
/// Sends `conversation_deleted` to our OTHER devices only (never the peer), then
/// deletes locally. The receiver honors it only from one of our own devices,
/// only for a 1:1, deletes without re-broadcasting, and is idempotent. Groups
/// are untouched (they propagate through leave commits).
class ConversationDeleteSyncService {
  ConversationDeleteSyncService(
    this._host, {
    required Future<void> Function(
            String conversationId, String body, void Function() onSealed)
        sendSelfControlNotifyingSealed,
    required Future<void> Function(String conversationId) deleteConversation,
    Duration sealTimeout = const Duration(seconds: 15),
  })  : _send = sendSelfControlNotifyingSealed,
        _deleteConversation = deleteConversation,
        _sealTimeout = sealTimeout;

  final NotifierServiceHost _host;
  final Future<void> Function(String, String, void Function()) _send;
  final Future<void> Function(String) _deleteConversation;
  final Duration _sealTimeout;

  /// The user deleted [conversationId]. For a 1:1 the control is minted FIRST
  /// (encrypting needs the crypto state the local delete wipes) but only its
  /// ENCRYPTION is awaited, never the network submit.
  Future<void> deleteAndSync(String conversationId) async {
    final convo = _host.conversation(conversationId);
    if (convo != null && convo.kind == ConversationKind.oneToOne) {
      final sealed = Completer<void>();
      void markSealed() {
        if (!sealed.isCompleted) sealed.complete();
      }

      final send = _send(
        conversationId,
        const MessageControl.conversationDeleted().encode(),
        markSealed,
      );
      unawaited(send.then((_) => markSealed(), onError: (_) => markSealed()));
      await sealed.future.timeout(_sealTimeout, onTimeout: () {});
    }
    await _deleteConversation(conversationId);
  }

  /// Applies an inbound `conversation_deleted` (inside the conversation's lock;
  /// takes none, sends nothing).
  Future<void> applyInbound({
    required String conversationId,
    required MessageControl control,
    required String senderDeviceId,
    required String myDeviceId,
  }) async {
    if (!control.isConversationDeleted) return;
    if (!await _host.isMyDeviceWarm(senderDeviceId, myDeviceId)) return;
    final live = _host.conversation(conversationId);
    if (live == null || live.kind != ConversationKind.oneToOne) return;
    await _host.deleteConversation(conversationId);
  }
}
