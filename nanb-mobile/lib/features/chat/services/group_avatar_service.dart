import 'dart:async';

import '../models/conversation_kind.dart';
import '../models/message_control.dart';
import 'notifier_service_host.dart';

/// Owns a group's photo: set/clear it (applied locally, fanned to the other
/// members, and self-synced to our own devices) and apply inbound group-avatar
/// controls. Only group admins may change it. The photo itself is an encrypted
/// media blob; this service only moves its descriptor JSON around.
class GroupAvatarService {
  GroupAvatarService(this._host);

  final NotifierServiceHost _host;

  /// Sets the group's photo to [descriptorJson], or clears it when null.
  /// No-op if unchanged or the conversation isn't a group.
  Future<void> setAvatar(String conversationId, String? descriptorJson) async {
    final live = _host.conversation(conversationId);
    if (live == null || live.kind != ConversationKind.group) return;
    final changed = await _host.runLocked(
        conversationId, () => applyLocked(conversationId, descriptorJson));
    if (changed != true) return;
    final control = (descriptorJson == null
            ? const MessageControl.groupAvatar(remove: true)
            : MessageControl.groupAvatar(avatarJson: descriptorJson))
        .encode();
    unawaited(_host.sendControl(conversationId, control));
    unawaited(_host.sendSelfControl(conversationId, control));
  }

  /// Applies a set/clear to the live group, persists and notifies; returns true
  /// iff it changed. The CALLER MUST HOLD the conversation lock.
  Future<bool> applyLocked(String conversationId, String? descriptorJson) async {
    final live = _host.conversation(conversationId);
    if (live == null || live.kind != ConversationKind.group) return false;
    if (live.groupAvatar == descriptorJson) return false;
    final updated = live.copyWith(groupAvatar: descriptorJson);
    _host.setConversation(conversationId, updated);
    await _host.db.upsertConversation(updated);
    _host.notifyHost();
    return true;
  }

  /// Applies an inbound group-avatar control. Honored only when the sending
  /// DEVICE belongs to a current group admin — otherwise any member (or a forged
  /// control) could replace the photo. Already inside the conversation's lock.
  Future<void> applyInbound({
    required String conversationId,
    required MessageControl control,
    required String senderDeviceId,
  }) async {
    final live = _host.conversation(conversationId);
    if (live == null || live.kind != ConversationKind.group) return;
    final senderIsAdmin = live.members
        .any((m) => m.deviceId == senderDeviceId && m.isAdmin);
    if (!senderIsAdmin) return;
    await applyLocked(
      conversationId,
      control.groupAvatarRemove ? null : control.groupAvatarJson,
    );
  }
}
