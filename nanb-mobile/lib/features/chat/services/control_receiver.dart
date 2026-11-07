import 'dart:async';

import '../models/chat_message.dart';
import '../models/conversation_kind.dart';
import '../models/message_control.dart';
import '../models/system_event.dart';
import 'account_deletion_notice.dart';
import 'view_once_service.dart';
import 'conversation_delete_sync_service.dart';
import 'conversation_state_applier.dart';
import 'delete_sync_service.dart';
import 'group_avatar_service.dart';
import 'group_disband_service.dart';
import 'pin_service.dart';
import 'reaction_service.dart';
import 'receipt_service.dart';
import 'request_decision_service.dart';
import 'notifier_service_host.dart';
import 'sealed_sender.dart';
import 'link_preview_service.dart';
import 'message_edit_service.dart';

/// Dispatches a decrypted inbound [MessageControl] to the right handler — the
/// receive-side counterpart to [ControlSender]. Routes receipts, request
/// decisions, privacy-flag broadcasts, sealed-sender access keys, reactions,
/// pins, and unsend to the already-extracted services. Always invoked from
/// INSIDE the conversation's decrypt lock, so handlers mutate inline and never
/// re-take the lock. Extracted from `ConversationsNotifier`.
class ControlReceiver {
  ControlReceiver({
    required NotifierServiceHost host,
    required ReceiptService receipts,
    required RequestDecisionService requestDecisions,
    required SealedSender sealedSender,
    required ReactionService reactions,
    required PinService pins,
    required GroupAvatarService groupAvatars,
    required LinkPreviewService linkPreviews,
    required MessageEditService edits,
    required DeleteSyncService deleteSync,
    required ConversationStateApplier stateApplier,
    required ConversationDeleteSyncService conversationDeleteSync,
    AccountDeletionNotice? accountDeletionNotice,
    ViewOnceService? viewOnce,
    required GroupDisbandService groupDisband,
    required Future<void> Function(String conversationId, ChatMessage message)
        deleteMessageLocal,
    required Future<void> Function(String conversationId, SystemEvent event)
        appendSystemEvent,
  })  : _host = host,
        _receipts = receipts,
        _requestDecisions = requestDecisions,
        _sealed = sealedSender,
        _reactions = reactions,
        _pins = pins,
        _groupAvatars = groupAvatars,
        _linkPreviews = linkPreviews,
        _edits = edits,
        _deleteSync = deleteSync,
        _stateApplier = stateApplier,
        _conversationDeleteSync = conversationDeleteSync,
        _accountDeletionNotice = accountDeletionNotice,
        _viewOnce = viewOnce,
        _groupDisband = groupDisband,
        _deleteMessageLocal = deleteMessageLocal,
        _appendSystemEvent = appendSystemEvent;

  final NotifierServiceHost _host;
  final ReceiptService _receipts;
  final RequestDecisionService _requestDecisions;
  final SealedSender _sealed;
  final ReactionService _reactions;
  final PinService _pins;
  final GroupAvatarService _groupAvatars;
  final LinkPreviewService _linkPreviews;
  final MessageEditService _edits;
  final DeleteSyncService _deleteSync;
  final ConversationStateApplier _stateApplier;
  final ConversationDeleteSyncService _conversationDeleteSync;
  final AccountDeletionNotice? _accountDeletionNotice;
  final ViewOnceService? _viewOnce;
  final GroupDisbandService _groupDisband;
  final Future<void> Function(String, ChatMessage) _deleteMessageLocal;
  final Future<void> Function(String, SystemEvent) _appendSystemEvent;

  /// Applies a received control payload. Unsend (the default case) deletes the
  /// referenced message if we have it (best-effort DB delete otherwise).
  Future<void> applyControl(
    String conversationId,
    MessageControl control,
    String senderDeviceId,
    String myDeviceId,
  ) async {
    if (control.isReestablish) {
      // No-op: the re-establishment Welcome that rode ahead of this control
      // already rebuilt the group. Decrypting this proves convergence.
      return;
    }
    if (control.isReceipt) {
      await _receipts.applyReceipt(
          conversationId, control.receiptKind!, control.receiptIds);
      return;
    }
    if (control.isRequestDecision) {
      // Only one of OUR OWN devices may resolve a request on our behalf — a
      // peer must not be able to clear our banner or (worse) delete our
      // conversation by forging this control.
      if (!await _host.isMyDeviceWarm(senderDeviceId, myDeviceId)) return;
      // A sibling device resolved this request — mirror it here.
      await _requestDecisions.applyInbound(
        conversationId: conversationId,
        decision: control.decision!,
      );
      return;
    }
    if (control.isPrivacy) {
      // The peer flipped a privacy toggle. A copy from one of OUR OWN
      // devices carries our own flags — not the peer's — so drop it.
      if (await _host.isMyDeviceWarm(senderDeviceId, myDeviceId)) return;
      final live = _host.conversation(conversationId);
      if (live == null || live.kind != ConversationKind.oneToOne) return;
      final s = control.privacyScreenshots!;
      final f = control.privacyForwarding!;
      if (live.peerBlocksScreenshots == s && live.peerBlocksForwarding == f) {
        return;
      }
      final updated = live.copyWith(
        peerBlocksScreenshots: s,
        peerBlocksForwarding: f,
      );
      _host.setConversation(conversationId, updated);
      await _host.db.upsertConversation(updated);
      _host.notifyHost();
      return;
    }
    if (control.isAccessKey) {
      // Sealed-sender Phase 2: a peer shared their UAK so we can deposit sealed
      // messages to them on the unauthenticated path. Accept ONLY from the peer
      // (our own devices derive our UAK locally), keyed by the peer's account.
      if (await _host.isMyDeviceWarm(senderDeviceId, myDeviceId)) return;
      final convo = _host.conversation(conversationId);
      if (convo == null) return;
      _sealed.applyAccessKey(convo, control.accessKey);
      return;
    }
    if (control.isReaction) {
      // Already inside this conversation's lock (called from the locked decrypt
      // path) — ReactionService.applyInbound resolves the reactor account and
      // mutates inline, without re-taking the lock.
      await _reactions.applyInbound(
        conversationId: conversationId,
        control: control,
        senderDeviceId: senderDeviceId,
        myDeviceId: myDeviceId,
      );
      return;
    }
    if (control.isEdit) {
      // Already inside this conversation's lock. Accepted only from the author.
      await _edits.applyInbound(
        conversationId: conversationId,
        control: control,
        senderDeviceId: senderDeviceId,
        myDeviceId: myDeviceId,
      );
      return;
    }
    if (control.isLinkPreview) {
      // Already inside this conversation's lock. The service accepts it only from
      // the target message's author, and only for a link the message contains.
      await _linkPreviews.applyInbound(
        conversationId: conversationId,
        control: control,
        senderDeviceId: senderDeviceId,
        myDeviceId: myDeviceId,
      );
      return;
    }
    if (control.isGroupAvatar) {
      // A group admin set/cleared the group photo (possibly one of our own
      // devices, self-synced). Already inside the conversation's lock.
      await _groupAvatars.applyInbound(
        conversationId: conversationId,
        control: control,
        senderDeviceId: senderDeviceId,
      );
      return;
    }
    if (control.isConversationState) {
      // A sibling device of OURS changed per-chat state (LWW per field). The
      // applier honors it only from an own device and never re-broadcasts.
      await _stateApplier.applyInbound(
        conversationId: conversationId,
        control: control,
        senderDeviceId: senderDeviceId,
        myDeviceId: myDeviceId,
      );
      return;
    }
    if (control.isViewOnceOpened) {
      await _viewOnce?.applyInbound(
        conversationId: conversationId,
        control: control,
        senderDeviceId: senderDeviceId,
        myDeviceId: myDeviceId,
      );
      return;
    }
    if (control.isAccountDeleted) {
      // The peer is deleting their account: their chat goes too.
      await _accountDeletionNotice?.applyInbound(
        conversationId: conversationId,
        control: control,
        senderDeviceId: senderDeviceId,
        myDeviceId: myDeviceId,
      );
      return;
    }
    if (control.isConversationDeleted) {
      // A sibling device of OURS deleted this 1:1. Own devices only; local
      // delete, nothing sent to the peer.
      await _conversationDeleteSync.applyInbound(
        conversationId: conversationId,
        control: control,
        senderDeviceId: senderDeviceId,
        myDeviceId: myDeviceId,
      );
      return;
    }
    if (control.isDeleteForMe) {
      // A sibling device of OURS removed a message with "Delete for me". The
      // service honors it only from an own device and never re-broadcasts.
      await _deleteSync.applyInbound(
        conversationId: conversationId,
        control: control,
        senderDeviceId: senderDeviceId,
        myDeviceId: myDeviceId,
      );
      return;
    }
    if (control.isGroupDeleted) {
      // A group admin disbanded the group. The service honors it only when the
      // sender is an admin in OUR roster (so a non-admin cannot delete it for
      // everyone). Local delete only; no lock re-taken, no leave commits.
      await _groupDisband.applyInbound(
        conversationId: conversationId,
        control: control,
        senderDeviceId: senderDeviceId,
      );
      return;
    }
    if (control.isPin) {
      // The conversation pin is a SHARED chat property: the peer OR one of our
      // own devices pinned/unpinned a message. Anyone in the chat may change it
      // (no own-device gate), last-write-wins. Already inside this
      // conversation's lock — apply inline.
      if (control.pinRemove) {
        // Clear only if the id still matches — a late unpin of an
        // already-replaced pin must not wipe the newer one. Empty target
        // (defensive) clears unconditionally.
        final live = _host.conversation(conversationId);
        final tgt = control.targetEnvelopeId;
        if (live != null && (tgt.isEmpty || live.pinnedEnvelopeId == tgt)) {
          await _pins.applyLocked(conversationId, null);
        }
      } else {
        await _pins.applyLocked(conversationId, control.targetEnvelopeId);
      }
      return;
    }
    if (control.isScreenshot) {
      // The peer screenshotted a chat we asked to keep screenshot-protected.
      // iOS can't block a still capture, so this notice IS the protection:
      // render an in-thread system line attributing it to them. Scoped to 1:1
      // (the privacy flags are), and always from the peer (never self-synced),
      // so the screenshotter is this conversation's peer. Already inside the
      // decrypt lock — append inline via the lock-free host callback.
      final live = _host.conversation(conversationId);
      if (live == null || live.kind != ConversationKind.oneToOne) return;
      await _appendSystemEvent(
        conversationId,
        SystemEvent.screenshotTaken(
          username: live.peerUsername,
          at: DateTime.now().toUtc(),
        ),
      );
      return;
    }
    // Unsend / delete-for-everyone (the default control). Honor it ONLY when
    // the control's sender is the AUTHOR of the target message — otherwise any
    // participant could delete anyone's messages for everyone (or a 1:1 peer
    // could silently delete YOUR sent messages from your device) just by naming
    // an envelope id.
    final live = _host.conversation(conversationId);
    final senderIsMe = await _host.isMyDeviceWarm(senderDeviceId, myDeviceId);
    final target = live?.messages
        .where((m) => m.envelopeId == control.targetEnvelopeId)
        .cast<ChatMessage?>()
        .firstWhere((_) => true, orElse: () => null);
    if (target != null) {
      // Author and unsender must be on the same side. `mine` marks messages
      // this account authored; a self-synced unsend arrives from one of our own
      // devices (senderIsMe). Opposite sides ⇒ someone is trying to delete a
      // message they didn't write.
      if (target.mine != senderIsMe) return;
      if (!senderIsMe &&
          live != null &&
          live.kind == ConversationKind.group &&
          senderDeviceId != target.senderDeviceId) {
        // In a group, a member may unsend only their OWN message: map both
        // device ids to their member account and require they match.
        String? accountFor(String dev) {
          for (final m in live.members) {
            if (m.deviceId == dev) return m.accountId;
          }
          return null;
        }

        final senderAccount = accountFor(senderDeviceId);
        final authorAccount = accountFor(target.senderDeviceId);
        if (senderAccount == null ||
            authorAccount == null ||
            senderAccount != authorAccount) {
          return;
        }
      }
      await _deleteMessageLocal(conversationId, target);
      return;
    }
    // Target isn't in our in-memory window, so we can't verify who wrote it.
    // Accept a blind DB delete ONLY when it is self-synced from one of our own
    // devices (our own unsend of our own message); never delete an unseen
    // message on a peer's unverifiable say-so.
    if (senderIsMe) {
      await _host.db.deleteMessage(control.targetEnvelopeId);
    }
  }
}
