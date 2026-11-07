import 'dart:async';

import '../models/conversation_kind.dart';
import '../models/message_control.dart';
import 'notifier_service_host.dart';

/// Tells everyone this account has a 1:1 with that the account is being
/// deleted, so their devices delete the chat with it. Sent before the server
/// deletes the account, because nothing can be encrypted after that.
///
/// The receiving side honors it only from the chat's peer (never from one of
/// its own devices) and only for a 1:1: groups are left with leave commits.
class AccountDeletionNotice {
  AccountDeletionNotice(
    this._host, {
    Duration perChatTimeout = const Duration(seconds: 10),
  }) : _perChatTimeout = perChatTimeout;

  final NotifierServiceHost _host;
  final Duration _perChatTimeout;

  /// Sends `account_deleted` to every device of every 1:1 peer. Returns how many
  /// chats it couldn't reach; the deletion goes ahead regardless.
  Future<int> notifyContacts() async {
    final body = const MessageControl.accountDeleted().encode();
    final chats = _host
        .allConversations()
        .where((c) =>
            c.kind == ConversationKind.oneToOne && c.peerAccountId.isNotEmpty)
        .toList(growable: false);
    var failed = 0;
    for (final c in chats) {
      try {
        await _host
            .sendControl(c.id, body, allPeerDevices: true)
            .timeout(_perChatTimeout);
      } catch (_) {
        failed++;
      }
    }
    return failed;
  }

  /// Applies an inbound `account_deleted`: the peer deleted their account, so
  /// the chat with them goes too. Runs inside the conversation's lock.
  Future<void> applyInbound({
    required String conversationId,
    required MessageControl control,
    required String senderDeviceId,
    required String myDeviceId,
  }) async {
    if (!control.isAccountDeleted) return;
    // Our own devices learn from the server revoking them, not from this.
    if (await _host.isMyDeviceWarm(senderDeviceId, myDeviceId)) return;
    final live = _host.conversation(conversationId);
    if (live == null || live.kind != ConversationKind.oneToOne) return;
    await _host.deleteConversation(conversationId);
  }
}
