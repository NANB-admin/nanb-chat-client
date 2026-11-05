import 'dart:convert';

import 'conversation_state_update.dart';
import 'link_preview.dart';
import 'sync_control_kind.dart';

/// Which receipt a [MessageControl.receipt] carries.
enum ReceiptKind { delivered, read }

/// How the user resolved an inbound message request — synced to their OWN
/// other devices so a linked device clears its pending banner (accept) or
/// drops the conversation (reject) in lock-step.
enum RequestDecision { accepted, rejected }

/// A control payload carried inside an otherwise-normal *encrypted* message
/// body. Control messages are never rendered as chat bubbles — the receiver
/// acts on them and drops them. Riding inside the normal message body means
/// they go through the same E2EE pipeline (so the server never sees the
/// intent) and advance the ratchet in lock-step like any other message.
///
/// Controls:
///   - `unsend` (delete-for-everyone): names the `envelope_id` of a
///     previously-sent message the peer should delete.
///   - `receipt`: tells the *original sender* that their message(s) were
///     delivered (decrypted on the peer's device) or read (peer opened the
///     conversation). Carries the referenced envelope ids.
///   - `privacy`: the sender's current conversation-privacy flags (block
///     screenshots / block forwarding), broadcast to every 1:1 when the
///     user flips a toggle so peers apply it immediately (the per-message
///     `PrivacyHeader` is the stateless fallback for everything else).
///   - `reaction`: an emoji reaction on a previously-sent message (named by
///     its `envelope_id`). `remove` clears the reactor's reaction; otherwise
///     it sets/replaces it (one reaction per person per message).
///   - `delete_for_me`: self-sync of "Delete for me" to the sender's OWN other
///     devices only (honored only from an own device).
///   - `group_deleted`: a group admin disbanded the group; honored only from a
///     roster admin (checked against the receiver's own roster).
///   - `conversation_state`: own-devices-only self-sync of per-chat settings
///     (sparse fields, last-writer-wins per field).  `conversation_deleted`:
///     own-devices-only delete of a 1:1.
///   - `screenshot`: tells the peer the user took a screenshot of a chat the
///     peer asked to keep screenshot-protected; the peer renders an in-thread
///     "took a screenshot" system line (the real protection on iOS, which
///     can't block a still capture). Carries no payload.
class MessageControl {
  const MessageControl.unsend(this.targetEnvelopeId)
      : receiptKind = null,
        receiptIds = const [],
        decision = null,
        privacyScreenshots = null,
        privacyForwarding = null,
        isReestablish = false,
        accessKey = const [],
        reactionEmoji = null,
        reactionRemove = false,
        isPinControl = false,
        pinRemove = false,
        isScreenshotControl = false,
        linkPreview = null,
        editedText = null,
        groupAvatarJson = null,
        groupAvatarRemove = false,
        syncKind = null,
        stateUpdate = null;

  const MessageControl.receipt(ReceiptKind kind, this.receiptIds)
      : targetEnvelopeId = '',
        receiptKind = kind,
        decision = null,
        privacyScreenshots = null,
        privacyForwarding = null,
        isReestablish = false,
        accessKey = const [],
        reactionEmoji = null,
        reactionRemove = false,
        isPinControl = false,
        pinRemove = false,
        isScreenshotControl = false,
        linkPreview = null,
        editedText = null,
        groupAvatarJson = null,
        groupAvatarRemove = false,
        syncKind = null,
        stateUpdate = null;

  const MessageControl.requestDecision(RequestDecision this.decision)
      : targetEnvelopeId = '',
        receiptKind = null,
        receiptIds = const [],
        privacyScreenshots = null,
        privacyForwarding = null,
        isReestablish = false,
        accessKey = const [],
        reactionEmoji = null,
        reactionRemove = false,
        isPinControl = false,
        pinRemove = false,
        isScreenshotControl = false,
        linkPreview = null,
        editedText = null,
        groupAvatarJson = null,
        groupAvatarRemove = false,
        syncKind = null,
        stateUpdate = null;

  const MessageControl.privacy({
    required bool screenshots,
    required bool forwarding,
  })  : targetEnvelopeId = '',
        receiptKind = null,
        receiptIds = const [],
        decision = null,
        privacyScreenshots = screenshots,
        privacyForwarding = forwarding,
        isReestablish = false,
        accessKey = const [],
        reactionEmoji = null,
        reactionRemove = false,
        isPinControl = false,
        pinRemove = false,
        isScreenshotControl = false,
        linkPreview = null,
        editedText = null,
        groupAvatarJson = null,
        groupAvatarRemove = false,
        syncKind = null,
        stateUpdate = null;

  /// A no-op control whose only job is to carry a re-establishment Welcome:
  /// when two devices end up with divergent MLS groups for a 1:1 (split
  /// brain — neither can decrypt the other), the designated side wipes its
  /// group and re-migrates, sending a fresh Welcome + this control so the
  /// peer adopts the new group. The receiver acts on the Welcome and drops
  /// this payload.
  const MessageControl.reestablish()
      : targetEnvelopeId = '',
        receiptKind = null,
        receiptIds = const [],
        decision = null,
        privacyScreenshots = null,
        privacyForwarding = null,
        isReestablish = true,
        accessKey = const [],
        reactionEmoji = null,
        reactionRemove = false,
        isPinControl = false,
        pinRemove = false,
        isScreenshotControl = false,
        linkPreview = null,
        editedText = null,
        groupAvatarJson = null,
        groupAvatarRemove = false,
        syncKind = null,
        stateUpdate = null;

  /// Sealed-sender Phase 2: shares THIS account's unidentified-access key (UAK)
  /// with a contact over the E2EE channel, so the contact can deposit sealed
  /// messages to us on the unauthenticated path (the server never sees the
  /// sender). The receiver stores it keyed by our account; it is never rendered.
  const MessageControl.accessKey(this.accessKey)
      : targetEnvelopeId = '',
        receiptKind = null,
        receiptIds = const [],
        decision = null,
        privacyScreenshots = null,
        privacyForwarding = null,
        isReestablish = false,
        reactionEmoji = null,
        reactionRemove = false,
        isPinControl = false,
        pinRemove = false,
        isScreenshotControl = false,
        linkPreview = null,
        editedText = null,
        groupAvatarJson = null,
        groupAvatarRemove = false,
        syncKind = null,
        stateUpdate = null;

  /// An emoji [reactionEmoji] reaction on the message named by
  /// [targetEnvelopeId]. [reactionRemove] true clears the reactor's reaction;
  /// false sets (or replaces) it. Fans out to the peer + self-syncs to the
  /// reactor's own devices like any other control.
  const MessageControl.reaction({
    required this.targetEnvelopeId,
    required String emoji,
    bool remove = false,
  })  : receiptKind = null,
        receiptIds = const [],
        decision = null,
        privacyScreenshots = null,
        privacyForwarding = null,
        isReestablish = false,
        accessKey = const [],
        reactionEmoji = emoji,
        reactionRemove = remove,
        isPinControl = false,
        pinRemove = false,
        isScreenshotControl = false,
        linkPreview = null,
        editedText = null,
        groupAvatarJson = null,
        groupAvatarRemove = false,
        syncKind = null,
        stateUpdate = null;

  /// Pins (or, with [remove] true, unpins) the message named by
  /// [targetEnvelopeId] for the WHOLE conversation. Unlike a reaction, the pin
  /// is a single shared chat property (one pin per chat, last-write-wins): it
  /// fans to the peer AND self-syncs to our own devices, and every participant
  /// may set or clear it. On remove, [targetEnvelopeId] is the id being cleared.
  const MessageControl.pin({
    required this.targetEnvelopeId,
    bool remove = false,
  })  : receiptKind = null,
        receiptIds = const [],
        decision = null,
        privacyScreenshots = null,
        privacyForwarding = null,
        isReestablish = false,
        accessKey = const [],
        reactionEmoji = null,
        reactionRemove = false,
        isPinControl = true,
        pinRemove = remove,
        isScreenshotControl = false,
        linkPreview = null,
        editedText = null,
        groupAvatarJson = null,
        groupAvatarRemove = false,
        syncKind = null,
        stateUpdate = null;

  /// Notifies the peer that the user just took a screenshot of a chat the peer
  /// asked to keep screenshot-protected (`peerBlocksScreenshots`). iOS cannot
  /// truly block a still screenshot, so detection + this notice IS the real
  /// protection there (Android blocks the capture outright). Peer-directed only
  /// (never self-synced); the receiver renders an in-thread "took a screenshot"
  /// system line. Carries no payload — the conversation + sender say the rest.
  const MessageControl.screenshot()
      : targetEnvelopeId = '',
        receiptKind = null,
        receiptIds = const [],
        decision = null,
        privacyScreenshots = null,
        privacyForwarding = null,
        isReestablish = false,
        accessKey = const [],
        reactionEmoji = null,
        reactionRemove = false,
        isPinControl = false,
        pinRemove = false,
        isScreenshotControl = true,
        linkPreview = null,
        editedText = null,
        groupAvatarJson = null,
        groupAvatarRemove = false,
        syncKind = null,
        stateUpdate = null;

  /// Attaches a link-preview card to the message named by [targetEnvelopeId].
  /// Sent by the message's AUTHOR after the message itself, once the preview has
  /// been fetched (over Tor, on the author's device), so the recipient never
  /// contacts the linked site. Fans to the peer + self-syncs like a reaction.
  const MessageControl.linkPreview({
    required this.targetEnvelopeId,
    required LinkPreview preview,
  })  : receiptKind = null,
        receiptIds = const [],
        decision = null,
        privacyScreenshots = null,
        privacyForwarding = null,
        isReestablish = false,
        accessKey = const [],
        reactionEmoji = null,
        reactionRemove = false,
        isPinControl = false,
        pinRemove = false,
        isScreenshotControl = false,
        linkPreview = preview,
        editedText = null,
        groupAvatarJson = null,
        groupAvatarRemove = false,
        syncKind = null,
        stateUpdate = null;

  /// Replaces the text of the message named by [targetEnvelopeId] with
  /// [text]. Sent by the message's AUTHOR; fans to the peer + self-syncs.
  const MessageControl.edit({
    required this.targetEnvelopeId,
    required String text,
  })  : receiptKind = null,
        receiptIds = const [],
        decision = null,
        privacyScreenshots = null,
        privacyForwarding = null,
        isReestablish = false,
        accessKey = const [],
        reactionEmoji = null,
        reactionRemove = false,
        isPinControl = false,
        pinRemove = false,
        isScreenshotControl = false,
        linkPreview = null,
        editedText = text,
        groupAvatarJson = null,
        groupAvatarRemove = false,
        syncKind = null,
        stateUpdate = null;

  /// Sets (descriptor JSON [avatarJson]) or, with [remove] true, clears the
  /// group's photo. Group-only; honored only from a group admin.
  const MessageControl.groupAvatar({String? avatarJson, bool remove = false})
      : targetEnvelopeId = '',
        receiptKind = null,
        receiptIds = const [],
        decision = null,
        privacyScreenshots = null,
        privacyForwarding = null,
        isReestablish = false,
        accessKey = const [],
        reactionEmoji = null,
        reactionRemove = false,
        isPinControl = false,
        pinRemove = false,
        isScreenshotControl = false,
        linkPreview = null,
        editedText = null,
        groupAvatarJson = avatarJson,
        groupAvatarRemove = remove,
        syncKind = null,
        stateUpdate = null;

  /// "Delete for me" self-sync: tells THIS account's other devices to drop the
  /// message named by [targetEnvelopeId]. Sent to own devices only (never the
  /// peer / group), honored only from an own device, and never re-broadcast.
  const MessageControl.deleteForMe(this.targetEnvelopeId)
      : receiptKind = null,
        receiptIds = const [],
        decision = null,
        privacyScreenshots = null,
        privacyForwarding = null,
        isReestablish = false,
        accessKey = const [],
        reactionEmoji = null,
        reactionRemove = false,
        isPinControl = false,
        pinRemove = false,
        isScreenshotControl = false,
        linkPreview = null,
        editedText = null,
        groupAvatarJson = null,
        groupAvatarRemove = false,
        syncKind = SyncControlKind.deleteForMe,
        stateUpdate = null;

  /// A group admin disbanded the group: every member device deletes it locally
  /// (no leave commits) and tombstones the id. Group-only; the receiver honors
  /// it only when the sender is an admin in ITS OWN roster.
  const MessageControl.groupDeleted()
      : targetEnvelopeId = '',
        receiptKind = null,
        receiptIds = const [],
        decision = null,
        privacyScreenshots = null,
        privacyForwarding = null,
        isReestablish = false,
        accessKey = const [],
        reactionEmoji = null,
        reactionRemove = false,
        isPinControl = false,
        pinRemove = false,
        isScreenshotControl = false,
        linkPreview = null,
        editedText = null,
        groupAvatarJson = null,
        groupAvatarRemove = false,
        syncKind = SyncControlKind.groupDeleted,
        stateUpdate = null;

  /// A 1:1 was deleted on one of this account's devices: the others delete it
  /// too. Own devices only; honored only from an own device; never re-broadcast.
  const MessageControl.conversationDeleted()
      : targetEnvelopeId = '',
        receiptKind = null,
        receiptIds = const [],
        decision = null,
        privacyScreenshots = null,
        privacyForwarding = null,
        isReestablish = false,
        accessKey = const [],
        reactionEmoji = null,
        reactionRemove = false,
        isPinControl = false,
        pinRemove = false,
        isScreenshotControl = false,
        linkPreview = null,
        editedText = null,
        groupAvatarJson = null,
        groupAvatarRemove = false,
        syncKind = SyncControlKind.conversationDeleted,
        stateUpdate = null;

  /// Self-sync of per-chat state (mute, pin, archive, timer, block, verified,
  /// background, read position, clear watermark): a sparse map of changed
  /// fields, each with its own LWW version. Own devices only.
  const MessageControl.conversationState(ConversationStateUpdate update)
      : targetEnvelopeId = '',
        receiptKind = null,
        receiptIds = const [],
        decision = null,
        privacyScreenshots = null,
        privacyForwarding = null,
        isReestablish = false,
        accessKey = const [],
        reactionEmoji = null,
        reactionRemove = false,
        isPinControl = false,
        pinRemove = false,
        isScreenshotControl = false,
        linkPreview = null,
        editedText = null,
        groupAvatarJson = null,
        groupAvatarRemove = false,
        syncKind = null,
        stateUpdate = update;

  /// The `envelope_id` of the message the control targets (unsend + reaction +
  /// pin).
  final String targetEnvelopeId;

  /// Non-null when this is a receipt control.
  final ReceiptKind? receiptKind;

  /// Envelope ids this receipt acknowledges (receipt only).
  final List<String> receiptIds;

  /// Non-null when this is a message-request decision (self-sync only).
  final RequestDecision? decision;

  /// Non-null when this is a privacy-flags control (both always set
  /// together): the SENDER's block-screenshots / block-forwarding flags.
  final bool? privacyScreenshots;
  final bool? privacyForwarding;

  /// True for the no-op re-establishment carrier control.
  final bool isReestablish;

  /// Non-empty when this is an access-key control: the sender's UAK bytes
  /// (sealed-sender Phase 2). Empty for every other control.
  final List<int> accessKey;

  /// Non-null when this is a reaction control: the emoji being added/removed.
  final String? reactionEmoji;

  /// Reaction only: true clears the reactor's reaction, false sets it.
  final bool reactionRemove;

  /// True for the conversation-pin control (discriminates it from `unsend`,
  /// which also carries only a [targetEnvelopeId]).
  final bool isPinControl;

  /// Pin only: true clears the chat's pin, false sets it to [targetEnvelopeId].
  final bool pinRemove;

  /// True for the screenshot-notification control (carries no other data, so
  /// it needs its own discriminator like the pin control does).
  final bool isScreenshotControl;

  /// Non-null when this is a link-preview control.
  final LinkPreview? linkPreview;

  /// Non-null when this is an edit control: the message's new text.
  final String? editedText;

  /// Group-photo control: the new descriptor JSON (set), or null when clearing.
  final String? groupAvatarJson;

  /// Group-photo control only: true clears the photo.
  final bool groupAvatarRemove;

  /// Non-null for the two payload-less sync controls (delete-for-me and
  /// group-deleted); null for every other control.
  final SyncControlKind? syncKind;

  /// Non-null for a `conversation_state` control.
  final ConversationStateUpdate? stateUpdate;

  bool get isConversationState => stateUpdate != null;
  bool get isConversationDeleted =>
      syncKind == SyncControlKind.conversationDeleted;
  bool get isDeleteForMe => syncKind == SyncControlKind.deleteForMe;
  bool get isGroupDeleted => syncKind == SyncControlKind.groupDeleted;
  bool get isGroupAvatar => groupAvatarJson != null || groupAvatarRemove;
  bool get isEdit => editedText != null;
  bool get isReceipt => receiptKind != null;
  bool get isRequestDecision => decision != null;
  bool get isPrivacy => privacyScreenshots != null;
  bool get isAccessKey => accessKey.isNotEmpty;
  bool get isReaction => reactionEmoji != null;
  bool get isPin => isPinControl;
  bool get isScreenshot => isScreenshotControl;
  bool get isLinkPreview => linkPreview != null;

  String encode() {
    if (isReceipt) {
      return jsonEncode({
        '_control': 'receipt',
        'kind': receiptKind!.name,
        'ids': receiptIds,
      });
    }
    if (isRequestDecision) {
      return jsonEncode({
        '_control': 'request_decision',
        'decision': decision!.name,
      });
    }
    if (isPrivacy) {
      return jsonEncode({
        '_control': 'privacy',
        'screenshots': privacyScreenshots,
        'forwarding': privacyForwarding,
      });
    }
    if (isReestablish) {
      return jsonEncode({'_control': 'reestablish'});
    }
    if (isAccessKey) {
      return jsonEncode({
        '_control': 'access_key',
        'uak': base64.encode(accessKey),
      });
    }
    if (isReaction) {
      return jsonEncode({
        '_control': 'reaction',
        'target': targetEnvelopeId,
        'emoji': reactionEmoji,
        if (reactionRemove) 'remove': true,
      });
    }
    if (isPin) {
      return jsonEncode({
        '_control': 'pin',
        'target': targetEnvelopeId,
        if (pinRemove) 'remove': true,
      });
    }
    if (isScreenshot) {
      return jsonEncode({'_control': 'screenshot'});
    }
    if (isGroupAvatar) {
      return jsonEncode({
        '_control': 'group_avatar',
        if (groupAvatarRemove) 'remove': true else 'avatar': groupAvatarJson,
      });
    }
    if (isEdit) {
      return jsonEncode({
        '_control': 'edit',
        'target': targetEnvelopeId,
        'text': editedText,
      });
    }
    if (isLinkPreview) {
      return jsonEncode({
        '_control': 'link_preview',
        'target': targetEnvelopeId,
        'preview': linkPreview!.toJson(),
      });
    }
    if (isDeleteForMe) {
      return jsonEncode({
        '_control': 'delete_for_me',
        'target': targetEnvelopeId,
      });
    }
    if (isGroupDeleted) {
      return jsonEncode({'_control': 'group_deleted'});
    }
    if (isConversationDeleted) {
      return jsonEncode({'_control': 'conversation_deleted'});
    }
    if (isConversationState) {
      return jsonEncode({
        '_control': 'conversation_state',
        'fields': stateUpdate!.toJson(),
      });
    }
    return jsonEncode({
      '_control': 'unsend',
      'target': targetEnvelopeId,
    });
  }

  /// Returns the control payload if [body] is one, else null. Fast-rejects
  /// anything that isn't a JSON object so normal text never pays the parse.
  static MessageControl? tryDecode(String body) {
    if (body.isEmpty || body.codeUnitAt(0) != 0x7B /* '{' */) return null;
    Object? raw;
    try {
      raw = jsonDecode(body);
    } catch (_) {
      return null;
    }
    if (raw is! Map) return null;
    switch (raw['_control']) {
      case 'unsend':
        final target = raw['target'];
        if (target is! String || target.isEmpty) return null;
        return MessageControl.unsend(target);
      case 'receipt':
        final kindStr = raw['kind'];
        final ids = raw['ids'];
        if (kindStr is! String || ids is! List) return null;
        ReceiptKind? kind;
        for (final k in ReceiptKind.values) {
          if (k.name == kindStr) kind = k;
        }
        if (kind == null) return null;
        final idList = ids.whereType<String>().toList();
        if (idList.isEmpty) return null;
        return MessageControl.receipt(kind, idList);
      case 'request_decision':
        final decStr = raw['decision'];
        if (decStr is! String) return null;
        for (final d in RequestDecision.values) {
          if (d.name == decStr) return MessageControl.requestDecision(d);
        }
        return null;
      case 'privacy':
        final s = raw['screenshots'];
        final f = raw['forwarding'];
        if (s is! bool || f is! bool) return null;
        return MessageControl.privacy(screenshots: s, forwarding: f);
      case 'reestablish':
        return const MessageControl.reestablish();
      case 'access_key':
        final uakStr = raw['uak'];
        if (uakStr is! String || uakStr.isEmpty) return null;
        final List<int> uak;
        try {
          uak = base64.decode(uakStr);
        } catch (_) {
          return null;
        }
        if (uak.isEmpty) return null;
        return MessageControl.accessKey(uak);
      case 'reaction':
        final target = raw['target'];
        final emoji = raw['emoji'];
        if (target is! String || target.isEmpty) return null;
        if (emoji is! String || emoji.isEmpty) return null;
        return MessageControl.reaction(
          targetEnvelopeId: target,
          emoji: emoji,
          remove: raw['remove'] == true,
        );
      case 'pin':
        final target = raw['target'];
        if (target is! String) return null;
        final remove = raw['remove'] == true;
        // A set must name a message; a clear may carry an empty target.
        if (target.isEmpty && !remove) return null;
        return MessageControl.pin(targetEnvelopeId: target, remove: remove);
      case 'screenshot':
        return const MessageControl.screenshot();
      case 'edit':
        final target = raw['target'];
        final text = raw['text'];
        if (target is! String || target.isEmpty) return null;
        if (text is! String || text.trim().isEmpty) return null;
        return MessageControl.edit(targetEnvelopeId: target, text: text);
      case 'group_avatar':
        if (raw['remove'] == true) {
          return const MessageControl.groupAvatar(remove: true);
        }
        final avatar = raw['avatar'];
        if (avatar is! String || avatar.isEmpty) return null;
        return MessageControl.groupAvatar(avatarJson: avatar);
      case 'link_preview':
        final target = raw['target'];
        if (target is! String || target.isEmpty) return null;
        final preview = LinkPreview.fromJson(raw['preview']);
        if (preview == null) return null;
        return MessageControl.linkPreview(
            targetEnvelopeId: target, preview: preview);
      case 'delete_for_me':
        final target = raw['target'];
        if (target is! String || target.isEmpty) return null;
        return MessageControl.deleteForMe(target);
      case 'group_deleted':
        return const MessageControl.groupDeleted();
      case 'conversation_deleted':
        return const MessageControl.conversationDeleted();
      case 'conversation_state':
        final fields = raw['fields'];
        if (fields is! Map) return null;
        final update = ConversationStateUpdate.fromJson(fields);
        return update == null ? null : MessageControl.conversationState(update);
      default:
        return null;
    }
  }
}
