import 'dart:async';

import '../../../core/models/envelope.dart' as wire;
import '../models/conversation_kind.dart';
import 'notifier_service_host.dart';

/// Owns the ephemeral "peer is typing" state for 1:1 conversations: applies
/// inbound typing signals (with a safety auto-clear timer in case the "stopped"
/// signal is dropped), exposes the per-conversation flag, and sends our own
/// typing signal. Nothing here is persisted or encrypted — typing is a
/// best-effort ephemeral relay. Extracted from `ConversationsNotifier`.
class TypingService {
  TypingService(this._host);

  final NotifierServiceHost _host;

  /// Per-conversation "peer is typing" flag (1:1 only). Ephemeral — set on an
  /// inbound typing signal, auto-cleared after a short window in case the
  /// "stopped" signal is dropped.
  final Map<String, bool> _peerTyping = {};
  final Map<String, Timer> _peerTypingTimers = {};

  /// True when the 1:1 peer is currently typing in [conversationId].
  bool isPeerTyping(String conversationId) =>
      _peerTyping[conversationId] ?? false;

  /// Applies an inbound ephemeral typing signal. Sets the per-conversation flag
  /// and arms a safety timer to clear it if the "stopped" signal is dropped.
  void onTyping(wire.Envelope env) {
    final convoId = env.conversationId;
    if (_host.conversation(convoId) == null) return;
    final typing = env.ciphertext.isNotEmpty && env.ciphertext.first == 1;
    _peerTypingTimers.remove(convoId)?.cancel();
    if (_peerTyping[convoId] != typing) {
      _peerTyping[convoId] = typing;
      _host.notifyHost();
    }
    if (typing) {
      _peerTypingTimers[convoId] = Timer(const Duration(seconds: 6), () {
        _peerTypingTimers.remove(convoId);
        if (_peerTyping[convoId] == true) {
          _peerTyping[convoId] = false;
          _host.notifyHost();
        }
      });
    }
  }

  /// Sends a typing signal to the 1:1 peer (best-effort, ephemeral — relayed by
  /// the server, never persisted). No-op for groups or when offline.
  void sendTyping(String conversationId, bool isTyping) {
    final convo = _host.conversation(conversationId);
    if (convo == null ||
        convo.kind != ConversationKind.oneToOne ||
        convo.peerDeviceId.isEmpty ||
        convo.blocked) {
      return;
    }
    _host.sendEphemeral({
      'type': wire.EnvelopeType.typing,
      'conversation_id': conversationId,
      'recipient_device_id': convo.peerDeviceId,
      'is_typing': isTyping,
    });
  }

  /// Cancel all safety timers and drop typing state. Call on notifier dispose
  /// and on sign-out / local-state wipe.
  void clear() {
    for (final t in _peerTypingTimers.values) {
      t.cancel();
    }
    _peerTypingTimers.clear();
    _peerTyping.clear();
  }
}
