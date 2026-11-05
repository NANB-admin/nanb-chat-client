import '../../../core/models/account.dart';
import '../media_pipeline.dart';
import '../models/conversation.dart';
import '../models/conversation_kind.dart';

/// In-memory cache of peers' presentation profile — display name + avatar
/// descriptor, keyed by account id, learned from account lookups. Drives the
/// chat-list / thread title + avatar. A pure cache with no dependencies (the
/// peer DEVICE list lives in [DeviceCache]; the notifier coordinates recording
/// both from one looked-up account). Extracted from `ConversationsNotifier`.
class PeerProfileCache {
  final Map<String, String> _displayNames = {};
  final Map<String, MediaDescriptor> _avatars = {};

  /// Cache [account]'s display name + avatar descriptor (best-effort; a blank
  /// name or malformed avatar is skipped, leaving the existing fallback).
  void record(Account account) {
    final dn = account.displayName?.trim();
    if (dn != null && dn.isNotEmpty) {
      _displayNames[account.accountId] = dn;
    }
    final av = account.avatarUrl;
    if (av != null && MediaDescriptor.looksLikeDescriptor(av)) {
      try {
        _avatars[account.accountId] = MediaDescriptor.fromJson(av);
      } catch (_) {/* malformed descriptor — keep initials */}
    }
  }

  /// The name to render for [c]: a group's name, else the peer's cached display
  /// name, else their `@username`.
  String displayNameFor(Conversation c) {
    if (c.kind == ConversationKind.group) {
      return c.groupName ?? '(unnamed group)';
    }
    return _displayNames[c.peerAccountId] ?? c.peerUsername;
  }

  /// The peer's avatar descriptor for a 1:1 conversation, or null when none is
  /// set (the UI falls back to initials).
  MediaDescriptor? avatarDescriptor(Conversation c) {
    if (c.kind == ConversationKind.group) return _groupPhoto(c.groupAvatar);
    if (c.kind != ConversationKind.oneToOne) return null;
    return _avatars[c.peerAccountId];
  }

  /// Decodes a group's photo descriptor JSON; null (initials/glyph) when absent
  /// or malformed.
  static MediaDescriptor? _groupPhoto(String? json) {
    if (json == null || json.isEmpty) return null;
    try {
      return MediaDescriptor.fromJson(json);
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }

  /// The cached display name for [accountId] (null if none) — for change
  /// detection on a profile refresh.
  String? nameOf(String accountId) => _displayNames[accountId];

  /// The cached avatar media id for [accountId] (null if none) — for change
  /// detection on a profile refresh.
  String? avatarMediaIdOf(String accountId) => _avatars[accountId]?.mediaId;

  /// Drop all cached profiles (sign-out / account switch).
  void clear() {
    _displayNames.clear();
    _avatars.clear();
  }
}
