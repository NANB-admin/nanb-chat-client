import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/chat_message.dart';
import '../models/conversation_kind.dart';
import '../../../core/push/push_kind.dart';
import '../models/message_control.dart';
import 'notifier_service_host.dart';

/// Owns emoji reactions: toggle the current user's reaction (applied locally,
/// fanned to the peer, self-synced to our own devices) and apply inbound
/// reaction controls. Reactions are keyed by the reactor's ACCOUNT id, so a
/// person's reaction dedups across their devices and "mine" stays detectable.
/// Extracted from `ConversationsNotifier`.
class ReactionService {
  ReactionService(this._host, {void Function(String conversationId)? onPeerReaction})
      : _onPeerReaction = onPeerReaction;

  final NotifierServiceHost _host;

  /// Called when the peer ADDS a reaction to one of our messages, so the app can
  /// raise a notification for it.
  final void Function(String conversationId)? _onPeerReaction;

  /// Toggle the current user's [emoji] reaction on [targetEnvelopeId]: clears it
  /// if already set to that emoji, else sets/replaces it (one per person). No-op
  /// if the message isn't local. Fans the change to the peer + our own devices.
  Future<void> react({
    required String conversationId,
    required String targetEnvelopeId,
    required String emoji,
  }) async {
    final me = await _host.currentAccountId();
    if (me == null || me.isEmpty) return;
    final live = _host.conversation(conversationId);
    final target = live?.messages
        .where((m) => m.envelopeId == targetEnvelopeId)
        .cast<ChatMessage?>()
        .firstWhere((_) => true, orElse: () => null);
    if (target == null) return;
    // Tapping the emoji you already reacted with removes it.
    final remove = target.reactions[me] == emoji;
    await _host.runLocked(
      conversationId,
      () => mutateLocked(conversationId, targetEnvelopeId, me, emoji, remove),
    );
    final control = MessageControl.reaction(
      targetEnvelopeId: targetEnvelopeId,
      emoji: emoji,
      remove: remove,
    ).encode();
    // Peer (relayed to the peer's devices) + our own other devices.
    // Adding a reaction should notify the peer; taking one back should not.
    unawaited(_host.sendControl(conversationId, control,
        pushKind: remove ? PushKind.silent : PushKind.reaction));
    unawaited(_host.sendSelfControl(conversationId, control));
  }

  /// Set/clear [reactor]'s reaction on a locally-stored message, persist, and
  /// notify. The CALLER MUST HOLD the conversation lock (invoked from [react]
  /// under `runLocked` and inline from the already-locked [applyInbound] path).
  Future<void> mutateLocked(
    String conversationId,
    String targetEnvelopeId,
    String reactor,
    String emoji,
    bool remove,
  ) async {
    final live = _host.conversation(conversationId);
    if (live == null) return;
    final idx =
        live.messages.indexWhere((m) => m.envelopeId == targetEnvelopeId);
    if (idx < 0) {
      // The target isn't in the loaded in-memory window (older / scrolled past).
      // Update the stored row directly so the reaction shows when it's next
      // loaded, instead of silently dropping it. No notify — nothing visible.
      final stored = await _host.db.getMessage(targetEnvelopeId);
      if (stored == null) return; // truly gone (trimmed / expired)
      final updatedStored = Map<String, String>.from(stored.reactions);
      if (remove) {
        updatedStored.remove(reactor);
      } else {
        updatedStored[reactor] = emoji;
      }
      if (mapEquals(updatedStored, stored.reactions)) return;
      await _host.db.upsertMessages(
          conversationId, [stored.copyWith(reactions: updatedStored)]);
      return;
    }
    final msg = live.messages[idx];
    final updated = Map<String, String>.from(msg.reactions);
    if (remove) {
      updated.remove(reactor);
    } else {
      updated[reactor] = emoji;
    }
    if (mapEquals(updated, msg.reactions)) return; // nothing changed
    final newMsg = msg.copyWith(reactions: updated);
    final msgs = [...live.messages];
    msgs[idx] = newMsg;
    _host.setConversation(conversationId, live.copyWith(messages: msgs));
    await _host.db.upsertMessages(conversationId, [newMsg]);
    _host.notifyHost();
  }

  /// Apply an inbound reaction [control]. Resolves the reactor's ACCOUNT id
  /// (our own device → us; a 1:1 → the peer; a group → the member's account),
  /// then mutates. The CALLER MUST HOLD the conversation lock (this runs on the
  /// already-locked decrypt path).
  Future<void> applyInbound({
    required String conversationId,
    required MessageControl control,
    required String senderDeviceId,
    required String myDeviceId,
  }) async {
    final live = _host.conversation(conversationId);
    if (live == null) return;
    String reactor;
    if (await _host.isMyDeviceWarm(senderDeviceId, myDeviceId)) {
      reactor = (await _host.currentAccountId()) ?? '';
    } else if (live.kind == ConversationKind.oneToOne) {
      reactor = live.peerAccountId;
    } else {
      reactor = live.members
              .where((m) => m.deviceId == senderDeviceId)
              .map((m) => m.accountId)
              .cast<String?>()
              .firstWhere((_) => true, orElse: () => null) ??
          '';
    }
    if (reactor.isEmpty) return;
    final target = live.messages
        .where((m) => m.envelopeId == control.targetEnvelopeId)
        .firstOrNull;
    final peerAddedToMine = target != null &&
        target.mine &&
        reactor != await _host.currentAccountId() &&
        !control.reactionRemove &&
        target.reactions[reactor] != control.reactionEmoji;
    await mutateLocked(
      conversationId,
      control.targetEnvelopeId,
      reactor,
      control.reactionEmoji!,
      control.reactionRemove,
    );
    if (peerAddedToMine) _onPeerReaction?.call(conversationId);
  }
}
