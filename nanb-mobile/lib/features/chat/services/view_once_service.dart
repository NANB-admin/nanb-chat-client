import '../models/chat_message.dart';
import '../models/message_control.dart';
import 'notifier_service_host.dart';

/// Keeps a view-once message's "opened" state the same on every device.
///
/// When the recipient opens it, their device empties it and sends
/// `view_once_opened` (carrying the sender's message id, the one id every
/// copy shares) to the sender's devices and to its own other devices. Each
/// device that gets it empties its copy too: the recipient's other devices so
/// it can't be opened twice, the sender's devices so they show "Opened".
class ViewOnceService {
  ViewOnceService(
    this._host, {
    required Future<void> Function(
            String conversationId, ChatMessage message, DateTime openedAt)
        empty,
  }) : _empty = empty;

  final NotifierServiceHost _host;
  final Future<void> Function(String, ChatMessage, DateTime) _empty;

  /// The id that names [message] on every device: the sender's client id, or
  /// the envelope id for a message that has none.
  static String sharedId(ChatMessage message) {
    final cid = message.clientMsgId;
    return cid != null && cid.isNotEmpty ? cid : message.envelopeId;
  }

  /// Applies an inbound `view_once_opened`. Runs inside the conversation lock.
  Future<void> applyInbound({
    required String conversationId,
    required MessageControl control,
    required String senderDeviceId,
    required String myDeviceId,
  }) async {
    if (!control.isViewOnceOpened) return;
    final live = _host.conversation(conversationId);
    if (live == null) return;
    final id = control.targetEnvelopeId;
    final target = live.messages
        .where((m) => m.viewOnce && sharedId(m) == id)
        .firstOrNull;
    if (target == null || target.viewOnceOpenedAt != null) return;
    final fromOwnDevice =
        await _host.isMyDeviceWarm(senderDeviceId, myDeviceId);
    // Our own device opened a message we received; or the peer opened one we
    // sent. Anything else (a peer claiming to open their own message) is noise.
    if (fromOwnDevice == target.mine) return;
    await _empty(conversationId, target, DateTime.now().toUtc());
  }
}
