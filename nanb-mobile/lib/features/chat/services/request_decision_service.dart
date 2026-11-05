import 'dart:async';

import '../models/conversation_kind.dart';
import '../models/message_control.dart';
import 'notifier_service_host.dart';

/// Resolves message requests (inbound 1:1 from a never-contacted sender) and
/// group invitations (a `pending` group from someone else's Welcome). Accept
/// unlocks the conversation; reject deletes it (1:1) or leaves the group. Every
/// decision self-syncs to our own other devices so a sibling resolves in
/// lock-step — the peer/group is never told (acceptance stays private).
/// Extracted from `ConversationsNotifier`.
class RequestDecisionService {
  RequestDecisionService(this._host);

  final NotifierServiceHost _host;

  /// Accept a 1:1 message request: clear `pending`, self-sync the accept, and
  /// (since the peer messaged first) tell them our privacy flags if set.
  Future<void> acceptMessageRequest(String conversationId) async {
    final convo = _host.conversation(conversationId);
    if (convo == null || !convo.pending) return;
    final updated = convo.copyWith(pending: false);
    _host.setConversation(conversationId, updated);
    await _host.db.upsertConversation(updated);
    _host.notifyHost();
    unawaited(_host.sendSelfControl(
      conversationId,
      const MessageControl.requestDecision(RequestDecision.accepted).encode(),
    ));
    // The peer messaged first, so they may never have seen our privacy flags
    // (the per-message header only rides OUR outgoing messages). Tell them on
    // accept — best-effort, like the self-sync above.
    final flags = _host.privacyFlags();
    if (flags != null && (flags.screenshots || flags.forwarding)) {
      unawaited(_host.sendControl(
        conversationId,
        MessageControl.privacy(
          screenshots: flags.screenshots,
          forwarding: flags.forwarding,
        ).encode(),
      ));
    }
  }

  /// Reject a 1:1 message request: self-sync the reject FIRST (while the group
  /// state still exists to encrypt with), then BLOCK the conversation (the
  /// sender is not notified). Reject = block — kept (not deleted) so the first
  /// message stays visible and the user can UN-REJECT later by unblocking
  /// (Settings → Blocked). While rejected, inbound from the sender arrives
  /// silently (no unread / no notification) and the send guard prevents
  /// replying. Clears `pending` so it's a decided request, not an open one.
  Future<void> rejectMessageRequest(String conversationId) async {
    await _host.sendSelfControl(
      conversationId,
      const MessageControl.requestDecision(RequestDecision.rejected).encode(),
    );
    final convo = _host.conversation(conversationId);
    if (convo != null && convo.pending) {
      final decided = convo.copyWith(pending: false);
      _host.setConversation(conversationId, decided);
      await _host.db.upsertConversation(decided);
    }
    // setBlocked sets the flag + mirrors the blocked set to SecureStorage so the
    // FCM background isolate also suppresses wake notifications.
    await _host.setBlocked(conversationId, true);
  }

  /// Accept a group invitation: clear `pending` + self-sync. The group is not
  /// told (acceptance stays private, like a 1:1 request).
  Future<void> acceptGroupInvite(String conversationId) async {
    final convo = _host.conversation(conversationId);
    if (convo == null || !convo.pending) return;
    final updated = convo.copyWith(pending: false);
    _host.setConversation(conversationId, updated);
    await _host.db.upsertConversation(updated);
    _host.notifyHost();
    unawaited(_host.sendSelfControl(
      conversationId,
      const MessageControl.requestDecision(RequestDecision.accepted).encode(),
    ));
  }

  /// Reject a group invitation by LEAVING the group properly: self-sync the
  /// reject FIRST (while still a member able to encrypt to our own devices),
  /// then remove our account from the MLS group (fans a removal Commit and
  /// deletes the conversation locally). If the roster hasn't landed yet we
  /// can't address a leave Commit, so fall back to a local-only delete.
  Future<void> rejectGroupInvite(String conversationId) async {
    final convo = _host.conversation(conversationId);
    if (convo == null) return;
    await _host.sendSelfControl(
      conversationId,
      const MessageControl.requestDecision(RequestDecision.rejected).encode(),
    );
    final myDeviceId = await _host.selfDeviceId();
    final amMember = convo.members.any((m) => m.deviceId == myDeviceId);
    if (amMember) {
      await _host.removeMemberFromGroup(
        conversationId: conversationId,
        targetDeviceId: myDeviceId,
      );
    } else {
      await _host.deleteConversation(conversationId);
    }
  }

  /// Mirror a self-synced [decision] from one of OUR OWN devices (the caller —
  /// the locked decrypt path — has already verified the sender is our device).
  /// Accept clears `pending`; reject BLOCKS a 1:1 (kept + un-rejectable) or
  /// drops a group (leaves it). CALLER HOLDS the lock; the group delete is
  /// scheduled post-lock (deleteConversation re-takes the same lock); the 1:1
  /// block path takes no lock so it runs inline.
  Future<void> applyInbound({
    required String conversationId,
    required RequestDecision decision,
  }) async {
    if (decision == RequestDecision.accepted) {
      final live = _host.conversation(conversationId);
      if (live != null && live.pending) {
        final updated = live.copyWith(pending: false);
        _host.setConversation(conversationId, updated);
        await _host.db.upsertConversation(updated);
        _host.notifyHost();
      }
      return;
    }
    // Rejected on a sibling device.
    final live = _host.conversation(conversationId);
    if (live != null && live.kind == ConversationKind.oneToOne) {
      // 1:1 → block (keep the conversation; un-rejectable via unblock).
      if (live.pending) {
        final decided = live.copyWith(pending: false);
        _host.setConversation(conversationId, decided);
        await _host.db.upsertConversation(decided);
        _host.notifyHost();
      }
      await _host.setBlocked(conversationId, true);
    } else {
      // Group → leave/delete (post-lock; deleteConversation re-takes the lock).
      unawaited(Future(() => _host.deleteConversation(conversationId)));
    }
  }
}
