import 'package:flutter/foundation.dart';

import 'chat_message.dart';
import 'conversation_kind.dart';
import 'crypto_mode.dart';
import 'group_member.dart';

/// Lightweight conversation summary used to render the chat list.
/// Sentinel for [Conversation.copyWith]'s nullable [pinnedEnvelopeId] so a
/// caller can tell "clear it" (`null`) apart from "leave unchanged" (omit).
const Object _unchanged = Object();

@immutable
class Conversation {
  const Conversation({
    required this.id,
    required this.peerUsername,
    required this.peerAccountId,
    required this.peerDeviceId,
    required this.peerIdentityPubKey,
    required this.messages,
    required this.unreadCount,
    this.peerX25519PubKey = const [],
    this.verified = false,
    this.hasMoreOlderMessages = false,
    this.cryptoMode = CryptoMode.ratchet,
    this.needsReestablishment = false,
    this.kind = ConversationKind.oneToOne,
    this.groupName,
    this.groupAvatar,
    this.members = const [],
    this.mlsEpoch,
    this.pending = false,
    this.pinned = false,
    this.pinnedEnvelopeId,
    this.muted = false,
    this.archived = false,
    this.blocked = false,
    this.peerBlocksScreenshots = false,
    this.peerBlocksForwarding = false,
    this.disappearingTtl = -1,
  });

  /// Stable ID used as both `conversation_id` on the wire and the routing
  /// segment in the URL. For 1:1 chats: `1to1:<sortedDevicePair>`. For
  /// groups (Plan C): `group:<uuidv4>`.
  final String id;

  final String peerUsername;
  final String peerAccountId;
  final String peerDeviceId;
  final List<int> peerIdentityPubKey;

  /// Peer's X25519 pub key — required for ECDH on the v1 baseline E2EE
  /// layer. Empty for legacy conversations (peer onboarded pre-Plan 13);
  /// the bridge throws on encrypt/decrypt in that case.
  final List<int> peerX25519PubKey;

  /// Messages ordered by `serverTs` ascending.
  final List<ChatMessage> messages;
  final int unreadCount;

  /// Set when the user has confirmed the safety number with the peer.
  /// Persisted across app launches via `AppDatabase`. Resets to `false` if
  /// either party's identity ever changes (UI compares the live safety
  /// number against the verified one).
  final bool verified;

  /// True iff at least one message older than `messages.first.serverTs`
  /// exists on disk. Drives the chat-thread "load more" affordance: the UI
  /// suppresses the spinner once this is false. Not persisted — recomputed
  /// from disk state on every hydrate / paginate.
  final bool hasMoreOlderMessages;

  /// Wire-protocol encryption mode. Defaults to [CryptoMode.ratchet] for new
  /// and pre-Plan-B conversations. Plan B's MlsMigrator flips this to
  /// [CryptoMode.mls] on the first successful outbound MLS send.
  final CryptoMode cryptoMode;

  /// True iff boot reconciliation found this convo in app DB as mls-mode
  /// but CoreCrypto can't open the corresponding group. UI surfaces a
  /// banner; user can tap to retry. Transient — not persisted. Resets
  /// to false on next successful reconciliation.
  final bool needsReestablishment;

  /// 1:1 vs group discriminator (spec §10.1). Defaults to [oneToOne]
  /// for backwards compatibility with all rows loaded from older schemas.
  final ConversationKind kind;

  /// Display name for group conversations. Null for 1:1.
  final String? groupName;

  /// Encrypted-media descriptor JSON for the group's photo (same shape as a
  /// profile avatar). Null when the group has no photo.
  final String? groupAvatar;

  /// Group membership projection. Empty for 1:1 conversations. The truth
  /// lives in CoreCrypto's MLS tree; this list is the UI/diagnostic
  /// projection rebuilt from the `group_members` table on load.
  final List<GroupMember> members;

  /// Current MLS epoch counter (diagnostic only — spec §8.2). Null for
  /// 1:1 (epoch isn't surfaced) and for not-yet-MLS conversations.
  final int? mlsEpoch;

  /// True for a "message request": the conversation was created by an
  /// INBOUND envelope from a sender the user never contacted. Messages
  /// still decrypt and persist (the user can read the request), but the
  /// composer is replaced with Accept/Reject until the user decides.
  /// Conversations the local user initiates are never pending. Persisted.
  final bool pending;

  /// Pinned to the top of the chat list (local-only preference). Persisted.
  final bool pinned;

  /// The `envelope_id` of the conversation's single pinned message, or null if
  /// nothing is pinned (one pin per chat). UNLIKE [pinned] (a local chat-list
  /// preference), this is a SHARED chat property: setting/clearing it fans a
  /// `MessageControl.pin` to the peer + our own devices, and any participant
  /// may change it (last-write-wins). Surfaced in the in-thread pinned banner.
  /// Persisted.
  final String? pinnedEnvelopeId;

  /// Muted: no notifications for inbound messages; a muted indicator shows
  /// in the chat list. Local-only. Persisted.
  final bool muted;

  /// Archived: hidden from the main chat list (shown under "Archived").
  /// A new inbound message un-archives the conversation. Local-only.
  final bool archived;

  /// Blocked: the user blocked this contact. Hidden from both chat lists
  /// (shown only under Settings → Blocked), the composer is replaced with an
  /// Unblock bar, no notifications fire, and inbound messages are kept for
  /// crypto continuity but don't bump the unread count or send receipts.
  /// Client-honored, local-only (the peer is not told). Persisted.
  final bool blocked;

  /// The PEER's conversation-privacy flags (1:1 only; always false for
  /// groups). Learned from the peer's `PrivacyHeader` riding their messages
  /// and from `MessageControl.privacy` toggle broadcasts; last-write-wins.
  /// When `peerBlocksScreenshots` is true the thread sets FLAG_SECURE while
  /// open; when `peerBlocksForwarding` is true the peer's messages hide the
  /// Forward and Copy actions. Honored client-side by this app. Persisted.
  final bool peerBlocksScreenshots;
  final bool peerBlocksForwarding;

  /// Per-conversation disappearing-messages override, in seconds. `-1` means
  /// "use the global default" ([AppPreferences.disappearingDefault]); any
  /// value `> 0` is an explicit retention the sender attaches to every message
  /// it sends in this conversation (rides the per-message `_ttl` header so the
  /// recipient expires on our timer). There is deliberately no "off" — like the
  /// global default, messages always expire; the user only picks how fast.
  /// Local-only send policy; persisted. Never 0.
  final int disappearingTtl;

  ChatMessage? get lastMessage => messages.isEmpty ? null : messages.last;

  /// True when [accountId] is an admin of this group's roster. Admin is recorded
  /// per member ROW, and only the creating device's row carries it (the admin's
  /// other devices are stored non-admin), so the question is asked by ACCOUNT.
  bool isGroupAdminAccount(String accountId) =>
      kind == ConversationKind.group &&
      accountId.isNotEmpty &&
      members.any((m) => m.accountId == accountId && m.isAdmin);

  /// True when [deviceId] belongs to an admin account of this group's roster.
  /// A device missing from the roster is never an admin.
  bool isGroupAdminDevice(String deviceId) {
    for (final m in members) {
      if (m.deviceId == deviceId) return isGroupAdminAccount(m.accountId);
    }
    return false;
  }

  /// True when THIS account is an admin of this group (it may disband it).
  bool get isSelfGroupAdmin =>
      kind == ConversationKind.group &&
      members.any((m) => m.isSelf && isGroupAdminAccount(m.accountId));

  /// [members] collapsed to one entry per ACCOUNT — a member is an account, not
  /// a device, and a multi-device member has several leaf rows. For UI (the
  /// member list, the "N members" count): the self/admin row wins. Keep raw
  /// [members] for per-device work (sender attribution, fan-out).
  List<GroupMember> get distinctMembers {
    final byAccount = <String, GroupMember>{};
    for (final m in members) {
      final existing = byAccount[m.accountId];
      if (existing == null ||
          (m.isSelf && !existing.isSelf) ||
          (m.isAdmin && !existing.isAdmin)) {
        byAccount[m.accountId] = m;
      }
    }
    return byAccount.values.toList(growable: false);
  }

  /// Account IDs allowed to download media sent in THIS conversation — the
  /// download audience passed to `POST /media/init` (`authorized_account_ids`).
  /// For a 1:1 it's the peer; for a group it's every member account. The server
  /// always folds in the uploader's own account (so the uploader's other devices
  /// self-sync), and an EMPTY result falls back to legacy open access — so a
  /// caller can pass this unconditionally, and a conversation with no known
  /// participants simply doesn't tighten access rather than breaking the upload.
  List<String> get mediaAudienceAccountIds {
    if (kind == ConversationKind.group) {
      return [
        for (final m in distinctMembers)
          if (m.accountId.isNotEmpty) m.accountId,
      ];
    }
    return peerAccountId.isEmpty ? const [] : [peerAccountId];
  }

  Conversation copyWith({
    List<ChatMessage>? messages,
    int? unreadCount,
    bool? verified,
    bool? hasMoreOlderMessages,
    CryptoMode? cryptoMode,
    bool? needsReestablishment,
    String? groupName,
    // Sentinel default lets a caller CLEAR the photo (pass `null` explicitly).
    Object? groupAvatar = _unchanged,
    List<GroupMember>? members,
    int? mlsEpoch,
    bool? pending,
    bool? pinned,
    // Sentinel default lets a caller CLEAR the pin (pass `null` explicitly) —
    // distinct from "leave unchanged" (omit the argument).
    Object? pinnedEnvelopeId = _unchanged,
    bool? muted,
    bool? archived,
    bool? blocked,
    bool? peerBlocksScreenshots,
    bool? peerBlocksForwarding,
    int? disappearingTtl,
    List<int>? peerIdentityPubKey,
    /// Re-points a 1:1 at a DIFFERENT device of the same peer account — the
    /// "they switched phones" repair. Everything else about the peer (account,
    /// username, keys) is identity and stays pinned; only which of their
    /// devices we address can legitimately change.
    String? peerDeviceId,
  }) {
    return Conversation(
      id: id,
      peerUsername: peerUsername,
      peerAccountId: peerAccountId,
      peerDeviceId: peerDeviceId ?? this.peerDeviceId,
      peerIdentityPubKey: peerIdentityPubKey ?? this.peerIdentityPubKey,
      peerX25519PubKey: peerX25519PubKey,
      messages: messages ?? this.messages,
      unreadCount: unreadCount ?? this.unreadCount,
      verified: verified ?? this.verified,
      hasMoreOlderMessages: hasMoreOlderMessages ?? this.hasMoreOlderMessages,
      cryptoMode: cryptoMode ?? this.cryptoMode,
      needsReestablishment: needsReestablishment ?? this.needsReestablishment,
      kind: kind,
      groupName: groupName ?? this.groupName,
      groupAvatar: identical(groupAvatar, _unchanged)
          ? this.groupAvatar
          : groupAvatar as String?,
      members: members ?? this.members,
      mlsEpoch: mlsEpoch ?? this.mlsEpoch,
      pending: pending ?? this.pending,
      pinned: pinned ?? this.pinned,
      pinnedEnvelopeId: identical(pinnedEnvelopeId, _unchanged)
          ? this.pinnedEnvelopeId
          : pinnedEnvelopeId as String?,
      muted: muted ?? this.muted,
      archived: archived ?? this.archived,
      blocked: blocked ?? this.blocked,
      peerBlocksScreenshots:
          peerBlocksScreenshots ?? this.peerBlocksScreenshots,
      peerBlocksForwarding: peerBlocksForwarding ?? this.peerBlocksForwarding,
      disappearingTtl: disappearingTtl ?? this.disappearingTtl,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! Conversation) return false;
    return id == other.id &&
        peerUsername == other.peerUsername &&
        peerAccountId == other.peerAccountId &&
        peerDeviceId == other.peerDeviceId &&
        unreadCount == other.unreadCount &&
        verified == other.verified &&
        hasMoreOlderMessages == other.hasMoreOlderMessages &&
        cryptoMode == other.cryptoMode &&
        needsReestablishment == other.needsReestablishment &&
        kind == other.kind &&
        groupName == other.groupName &&
        groupAvatar == other.groupAvatar &&
        listEquals(members, other.members) &&
        mlsEpoch == other.mlsEpoch &&
        pending == other.pending &&
        pinnedEnvelopeId == other.pinnedEnvelopeId &&
        muted == other.muted &&
        disappearingTtl == other.disappearingTtl &&
        peerBlocksScreenshots == other.peerBlocksScreenshots &&
        peerBlocksForwarding == other.peerBlocksForwarding;
  }

  @override
  int get hashCode => Object.hash(
        id,
        peerUsername,
        peerAccountId,
        peerDeviceId,
        unreadCount,
        verified,
        hasMoreOlderMessages,
        cryptoMode,
        needsReestablishment,
        kind,
        groupName,
        groupAvatar,
        Object.hashAll(members),
        mlsEpoch,
        pending,
        pinnedEnvelopeId,
        muted,
        disappearingTtl,
        peerBlocksScreenshots,
        peerBlocksForwarding,
      );

  /// Builds the deterministic 1:1 conversation ID from the two participants'
  /// **account IDs** (sorted lexically so both sides agree).
  ///
  /// Must be account IDs, not device IDs: each side only learns the *account*
  /// of its peer (via username lookup), and device IDs differ per participant —
  /// so a device-based ID would never match across the two devices and inbound
  /// envelopes would never reconcile with the local conversation.
  static String oneToOneId(String accountA, String accountB) {
    final pair = [accountA, accountB]..sort();
    return '1to1:${pair[0]}:${pair[1]}';
  }
}
