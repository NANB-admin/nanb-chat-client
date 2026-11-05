import 'dart:async';

import '../models/conversation_kind.dart';
import '../models/message_control.dart';
import 'notifier_service_host.dart';

/// Lets a group ADMIN delete a group for EVERYONE.
///
/// Disbanding is a `group_deleted` control sent to every member device through
/// the normal E2EE group send path (the admin's own other devices are members,
/// so they get it too). Each receiving device verifies the sender is an admin in
/// ITS OWN roster before acting, then deletes the group locally and tombstones
/// the id — without emitting leave commits, since the group is being dissolved.
class GroupDisbandService {
  GroupDisbandService(
    this._host, {
    Duration sealTimeout = const Duration(seconds: 15),
  }) : _sealTimeout = sealTimeout;

  final NotifierServiceHost _host;

  /// How long the admin's delete waits for the control to be ENCRYPTED (not
  /// delivered) before deleting regardless — see [disband].
  final Duration _sealTimeout;

  /// Whether this account may disband [conversationId] (a group it administers).
  bool canDisband(String conversationId) =>
      _host.conversation(conversationId)?.isSelfGroupAdmin ?? false;

  /// Disbands the group: tell every member device, then delete it locally.
  /// Returns false (doing nothing) unless the conversation is a group this
  /// account administers.
  ///
  /// Ordering: the control is minted FIRST because encrypting it needs the live
  /// MLS group that the local delete wipes. But only the ENCRYPTION is awaited
  /// (a local, fast step) — never the network submit, which is a full E2EE send
  /// on the per-conversation lock and can retry for many seconds. The submit
  /// keeps running detached after the wipe, working from the already-minted
  /// ciphertext. A send that fails before it could even encrypt, or one that
  /// takes longer than [_sealTimeout] to reach encryption (lock contention),
  /// does not hold the delete hostage: the group is still deleted locally.
  Future<bool> disband(String conversationId) async {
    if (!canDisband(conversationId)) return false;
    final sealed = Completer<void>();
    void markSealed() {
      if (!sealed.isCompleted) sealed.complete();
    }

    final send = _host.sendControlNotifyingSealed(
      conversationId,
      const MessageControl.groupDeleted().encode(),
      onSealed: markSealed,
    );
    // Whether the send finishes or throws, nothing more to wait for; a throw
    // before encryption must not leave the delete waiting on the timeout.
    unawaited(send.then((_) => markSealed(), onError: (_) => markSealed()));
    await sealed.future.timeout(_sealTimeout, onTimeout: () {});
    await _host.disbandGroupLocally(conversationId);
    return true;
  }

  /// Applies an inbound `group_deleted`. Honored only for a group we hold, and
  /// only when the (MLS-authenticated) sending device belongs to an admin in
  /// OUR OWN roster — a non-admin member, a stranger, or a forged control is
  /// ignored. An admin's own other device passes the same check (account-level).
  /// Runs inside the conversation's lock; the local delete takes none.
  Future<void> applyInbound({
    required String conversationId,
    required MessageControl control,
    required String senderDeviceId,
  }) async {
    if (!control.isGroupDeleted) return;
    final live = _host.conversation(conversationId);
    if (live == null || live.kind != ConversationKind.group) return;
    if (!live.isGroupAdminDevice(senderDeviceId)) return;
    await _host.disbandGroupLocally(conversationId);
  }
}
