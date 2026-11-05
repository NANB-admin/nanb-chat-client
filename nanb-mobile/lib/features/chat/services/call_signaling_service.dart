import 'dart:async';

import '../../calls/models/call_signal.dart';
import '../models/chat_message.dart';
import '../models/conversation_kind.dart';
import '../models/crypto_mode.dart';
import '../models/message_kind.dart';
import '../models/system_event.dart';
import 'notifier_service_host.dart';

/// 1:1 voice/video call signaling helpers: whether a conversation is callable,
/// sending a [CallSignal] over the E2EE control path, and appending a
/// local-only call-log line. The inbound-signal dispatch hook stays on the
/// notifier (it's an external integration point set by the call layer).
/// Extracted from `ConversationsNotifier`.
class CallSignalingService {
  CallSignalingService(this._host);

  final NotifierServiceHost _host;

  /// True when [conversationId] is a 1:1 you may place/receive a call in: an
  /// accepted (non-pending), non-blocked conversation whose peer is addressable.
  /// This is the "can only call open, accepted chats" rule (spec condition 4).
  bool isCallable(String conversationId) {
    final c = _host.conversation(conversationId);
    return c != null &&
        c.kind == ConversationKind.oneToOne &&
        !c.pending &&
        !c.blocked &&
        c.peerDeviceId.isNotEmpty &&
        (c.cryptoMode == CryptoMode.mls || c.peerX25519PubKey.isNotEmpty);
  }

  /// Encrypts + submits a call [signal] to the peer of [conversationId] over the
  /// SAME E2EE path as a chat control message — never rendered. The server
  /// relays only ciphertext and pushes if the peer is offline (so an invite can
  /// ring a sleeping device). [allPeerDevices] rings every device the peer has;
  /// [toDeviceId] answers the one device that is actually in the call.
  Future<void> sendCallSignal(String conversationId, CallSignal signal,
          {String? pushKind, String? toDeviceId, bool allPeerDevices = false}) =>
      _host.sendControl(conversationId, signal.encode(),
          pushKind: pushKind,
          toDeviceId: toDeviceId,
          allPeerDevices: allPeerDevices);

  /// Appends a LOCAL-ONLY call-log entry to [conversationId] (never sent on the
  /// wire — the peer keeps their own). [outgoing] is the direction; [outcome] is
  /// one of `completed` | `missed` | `declined` | `failed` | `cancelled`;
  /// [durationSeconds] is set for a completed call. Rendered as a system line.
  Future<void> appendCallLog({
    required String conversationId,
    required bool outgoing,
    required String outcome,
    int? durationSeconds,
    bool video = false,
  }) {
    return _host.runLocked(conversationId, () async {
      final convo = _host.conversation(conversationId);
      if (convo == null) return;
      final now = DateTime.now().toUtc();
      final msg = ChatMessage(
        envelopeId: 'local-call-${now.microsecondsSinceEpoch}',
        conversationId: conversationId,
        senderDeviceId: 'system',
        body: SystemEvent.call(
          outgoing: outgoing,
          outcome: outcome,
          durationSeconds: durationSeconds,
          video: video,
          at: now,
        ).toJsonString(),
        serverTs: now,
        mine: false,
        kind: MessageKind.system,
      );
      _host.setConversation(
        conversationId,
        convo.copyWith(messages: [...convo.messages, msg]),
      );
      await _host.db.upsertMessages(conversationId, [msg]);
      _host.notifyHost();
    });
  }
}
