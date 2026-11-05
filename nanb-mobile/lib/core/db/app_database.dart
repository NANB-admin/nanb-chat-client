import '../../features/chat/models/chat_message.dart';
import '../../features/chat/models/conversation.dart';
import '../../features/chat/models/conversation_kind.dart';
import '../../features/chat/models/crypto_mode.dart';
import '../../features/chat/models/group_member.dart';
import '../../features/chat/models/message_kind.dart';
import '../crypto/conversation_crypto_state.dart';

/// Thrown by [AppDatabase.open] when the on-disk database exists but cannot be
/// opened — the SQLCipher key doesn't match the file (a lost/rotated key) or
/// the file is corrupt — and the caller did NOT opt into wiping it
/// (`recreateIfUnreadable: false`). Surfacing this instead of letting the raw
/// sqflite error propagate lets the caller choose a non-destructive degrade
/// (e.g. fall back to an in-memory store, preserving the file for a later
/// recovery attempt) over silently wedging start-up.
class DatabaseUnreadableException implements Exception {
  const DatabaseUnreadableException(this.path, this.cause);

  /// The database file that could not be opened.
  final String path;

  /// The underlying error (e.g. the sqflite "file is not a database" failure).
  final Object cause;

  @override
  String toString() => 'DatabaseUnreadableException($path): $cause';
}

/// Local-data layer abstraction. v1 schema persists `conversations` +
/// `messages` for offline render + restart durability. Master key is a
/// random 32-byte hex string stored in `SecureStorage`.
abstract class AppDatabase {
  /// Opens the underlying database. Must be called before any read/write.
  /// `masterKeyHex` is the SQLCipher key.
  ///
  /// If the on-disk file exists but can't be decrypted/read, behaviour depends
  /// on [recreateIfUnreadable]:
  ///   - `true` — delete the unreadable file and create a fresh, empty database.
  ///     Lossless ONLY when the caller knows the file is provably unrecoverable
  ///     (e.g. the SQLCipher key was just regenerated, so no key that could ever
  ///     decrypt it still exists). It discards whatever was on disk — use with
  ///     care.
  ///   - `false` (default) — throw [DatabaseUnreadableException] rather than
  ///     destroy possibly-recoverable encrypted history.
  Future<void> open({
    required String masterKeyHex,
    bool recreateIfUnreadable = false,
  });

  Future<void> close();

  /// True if `open` has completed successfully and the connection is alive.
  bool get isOpen;

  /// Loads every persisted conversation, each hydrated with its most recent
  /// `messagesPerConversation` messages (oldest → newest). Older messages
  /// stay on disk and are reachable via [loadMessages] when the user scrolls
  /// up. The default keeps the open-chat path snappy on cold start; raise it
  /// only when you actually need bulk history (e.g. test fixtures).
  Future<List<Conversation>> loadConversations({
    int messagesPerConversation = 50,
  });

  /// Page through a conversation's messages. Returns up to [limit] messages,
  /// ascending by `serverTs`. When [beforeServerTsMs] is non-null, returns
  /// only messages with `serverTs` strictly older than the cursor — pass the
  /// oldest currently-loaded message's `serverTs.millisecondsSinceEpoch` to
  /// fetch the next older page. When null, returns the most recent [limit]
  /// messages.
  Future<List<ChatMessage>> loadMessages(
    String conversationId, {
    required int limit,
    int? beforeServerTsMs,
  });

  /// Search a single conversation's **text** messages whose body contains
  /// [query] (case-insensitive substring). Returns matches newest first
  /// (`serverTs` descending, newest → oldest), capped to the newest [limit]. An empty
  /// query returns an empty list. Local-only — never touches the network. Media
  /// captions and system events are excluded (only `kind == text`).
  Future<List<ChatMessage>> searchMessages(
    String conversationId,
    String query, {
    int limit = 200,
  });

  /// Upsert the conversation row (peer fields + unread_count). Does NOT touch
  /// the conversation's messages — call `upsertMessages` for those.
  Future<void> upsertConversation(Conversation conversation);

  /// Persists [conversation] and [messages] in a SINGLE transaction.
  ///
  /// The receive path appends one message at a time, and calling
  /// [upsertConversation] then [upsertMessages] cost TWO commits per envelope —
  /// on an encrypted store every commit pays its own crypto and fsync, which is
  /// pure overhead on a catchup drain of dozens of messages. Also makes the
  /// pair atomic: a crash between the two writes previously left a conversation
  /// summary pointing at a message that was never stored.
  Future<void> upsertConversationWithMessages(
      Conversation conversation, List<ChatMessage> messages);

  /// Removes the conversation and cascades to its messages.
  Future<void> deleteConversation(String conversationId);

  /// Deletes every message in [conversationId] but KEEPS the conversation row
  /// (and any group membership). Backs "Clear chat history" — the contact /
  /// group stays, only the local transcript is wiped.
  Future<void> clearMessagesForConversation(String conversationId);

  /// Fetch a single stored message by its `envelopeId`, or null if absent.
  /// Used to mutate a message that isn't in the loaded in-memory window (e.g.
  /// applying a reaction to an older message).
  Future<ChatMessage?> getMessage(String envelopeId);

  /// Whether a message from [senderDeviceId] carrying [clientMsgId] already
  /// exists in [conversationId]. Backs resend deduplication: a lost-ack
  /// auto-resend arrives with the SAME sender-stamped client id as the original,
  /// so the receiver drops it instead of rendering the message twice. Backed by
  /// a partial index on `client_msg_id`.
  Future<bool> hasMessageWithClientId(
    String conversationId,
    String senderDeviceId,
    String clientMsgId,
  );

  /// Upsert one or more messages in a conversation. Existing rows with the
  /// same `envelopeId` are overwritten — used to swap an outbox entry for the
  /// server-acked one.
  Future<void> upsertMessages(String conversationId, List<ChatMessage> messages);

  /// Remove a single message by id (used when an outbox entry is replaced
  /// with a server-acked envelope under a different id).
  Future<void> deleteMessage(String envelopeId);

  /// Trim a conversation's messages to the most recent `keep`. No-op if the
  /// conversation has fewer messages.
  Future<void> trimMessages(String conversationId, {required int keep});

  /// Wipe everything. Used on sign-out / delete-account.
  Future<void> clearAll();

  /// Closes the connection and removes the underlying file. After this the
  /// next `open` will create a fresh database — used during delete-account
  /// to rotate the SQLCipher master key alongside the cleared content.
  Future<void> deleteFile();

  /// This device's local retention: drops every message whose
  /// `serverTs + effectiveTtl` is at or before [now], where the effective TTL is
  /// the per-conversation override (`conversations.disappearing_ttl` seconds, when
  /// > 0) else [globalTtlSeconds]. A message in a conversation with no override and
  /// a null global has no local retention and is left to [deleteExpiredMessages].
  /// Applies the CURRENT setting retroactively (independent of any sender-stamped
  /// expiry), so together with [deleteExpiredMessages] a message disappears at the
  /// SHORTER of its sender's timer and this device's setting. Returns rows removed.
  Future<int> deleteMessagesPastLocalRetention(DateTime now, int? globalTtlSeconds);

  /// Drops every message whose per-message `expiresAt` is at or before [now] —
  /// the sender-controlled disappearing path. Rows with no expiry are left to
  /// [deleteMessagesPastLocalRetention]. Returns the number of rows removed.
  Future<int> deleteExpiredMessages(DateTime now);

  /// Loads the ratchet state for one (conversation, peer device) pair, or null
  /// if none exists. [peerDeviceId] empty is the conversation's primary peer
  /// device (the single-device baseline); multi-device callers pass a specific
  /// device id to address one of the peer's other devices.
  Future<ConversationCryptoState?> loadConversationCryptoState(
    String conversationId, {
    String peerDeviceId,
  });

  /// Upserts a ratchet state, keyed by (conversationId, state.peerDeviceId).
  /// Caller persists after every successful encrypt or decrypt to maintain
  /// forward secrecy across restarts.
  Future<void> saveConversationCryptoState(ConversationCryptoState state);

  /// Removes ALL ratchet state for a conversation (every peer-device pair).
  /// Called on MLS migration / full re-establishment so orphaned ratchet rows
  /// no longer occupy space.
  Future<void> deleteConversationCryptoState(String conversationId);

  /// Replace the full membership of [conversationId] with [members]. Used
  /// after create-group and on add/remove-member operations to keep the
  /// projection table in sync with CoreCrypto. Atomic: deletes the old
  /// rows for the conversation, then inserts the new ones, in a single
  /// transaction.
  Future<void> upsertGroupMembers(
    String conversationId,
    List<GroupMember> members,
  );

  /// Read the membership projection for [conversationId]. Returns an empty
  /// list if none stored (i.e. for 1:1 conversations or freshly-restored
  /// devices that haven't reconciled yet).
  Future<List<GroupMember>> getGroupMembers(String conversationId);

  /// Drop one row by deviceId. Used on remove-member.
  Future<void> deleteGroupMember(String conversationId, String deviceId);

  /// Wipe all membership rows for [conversationId]. Used on leave-group +
  /// account-deletion.
  Future<void> deleteGroupMembersForConversation(String conversationId);

  /// Update the group_name + mls_epoch columns on the conversation row.
  /// Used on create, rename, and epoch-change events.
  Future<void> updateConversationGroupFields(
    String conversationId, {
    String? groupName,
    int? mlsEpoch,
  });

  /// Tombstone a group the user deleted, so envelopes still queued for it on
  /// the server (a roster broadcast, a message sent before our leave Commit
  /// landed) are acked+dropped instead of resurrecting the conversation as a
  /// fresh "new group" request. Without this a deleted group is unkillable:
  /// the residual envelopes are never decryptable (the local MLS group is
  /// gone) and never acked, so every catchup re-creates the placeholder.
  /// Idempotent.
  Future<void> markGroupDeleted(String conversationId);

  /// Lift the tombstone for [conversationId] — a genuine re-invite (an MLS
  /// Welcome) is a deliberate act by an admin and must be allowed through.
  Future<void> clearGroupDeleted(String conversationId);

  /// Every tombstoned group id. Loaded once on hydration into the notifier's
  /// in-memory gate.
  Future<Set<String>> loadDeletedGroupIds();
}

/// In-memory implementation usable in unit tests AND in the rare prod case
/// where SQLCipher fails to open (we degrade to in-memory rather than crash;
/// the user still gets a working session, just without restart durability).
class AppDatabaseInMemory implements AppDatabase {
  bool _open = false;
  final Map<String, _ConvoRow> _convos = {};
  final Map<String, List<ChatMessage>> _messages = {};
  final Map<String, ConversationCryptoState> _cryptoStates = {};
  final Map<String, List<GroupMember>> _members = {};
  final Map<String, ConversationKind> _kinds = {};
  final Map<String, _GroupFields> _groupFields = {};
  final Set<String> _deletedGroups = {};

  @override
  bool get isOpen => _open;

  @override
  Future<void> open({
    required String masterKeyHex,
    bool recreateIfUnreadable = false,
  }) async {
    _open = true;
  }

  @override
  Future<void> close() async {
    _open = false;
  }

  @override
  Future<List<Conversation>> loadConversations({
    int messagesPerConversation = 50,
  }) async {
    final out = <Conversation>[];
    for (final entry in _convos.entries) {
      final id = entry.key;
      final row = entry.value;
      final msgs = List<ChatMessage>.from(_messages[id] ?? const <ChatMessage>[]);
      msgs.sort((a, b) => a.serverTs.compareTo(b.serverTs));
      final tail = msgs.length > messagesPerConversation
          ? msgs.sublist(msgs.length - messagesPerConversation)
          : msgs;
      // hasMoreOlderMessages is true iff there's at least one message on disk
      // older than what we just loaded. Saves the notifier from a probe
      // query immediately after hydration.
      final hasMore = msgs.length > tail.length;
      final fields = _groupFields[id];
      out.add(Conversation(
        id: id,
        peerUsername: row.peerUsername,
        peerAccountId: row.peerAccountId,
        peerDeviceId: row.peerDeviceId,
        peerIdentityPubKey: List<int>.from(row.peerIdentityPubKey),
        peerX25519PubKey: List<int>.from(row.peerX25519PubKey),
        messages: tail,
        unreadCount: row.unreadCount,
        verified: row.verified,
        hasMoreOlderMessages: hasMore,
        cryptoMode: row.cryptoMode,
        kind: _kinds[id] ?? ConversationKind.oneToOne,
        groupName: fields?.groupName,
        members: List.unmodifiable(_members[id] ?? const []),
        mlsEpoch: fields?.mlsEpoch,
        pending: row.pending,
        pinned: row.pinned,
        pinnedEnvelopeId: row.pinnedEnvelopeId,
        muted: row.muted,
        archived: row.archived,
        blocked: row.blocked,
        disappearingTtl: row.disappearingTtl,
      ));
    }
    return out;
  }

  @override
  Future<List<ChatMessage>> loadMessages(
    String conversationId, {
    required int limit,
    int? beforeServerTsMs,
  }) async {
    final list = _messages[conversationId];
    if (list == null || list.isEmpty || limit <= 0) return const [];
    final sorted = List<ChatMessage>.from(list)
      ..sort((a, b) => a.serverTs.compareTo(b.serverTs));
    final filtered = beforeServerTsMs == null
        ? sorted
        : sorted
            .where((m) => m.serverTs.millisecondsSinceEpoch < beforeServerTsMs)
            .toList(growable: false);
    if (filtered.isEmpty) return const [];
    return filtered.length > limit
        ? filtered.sublist(filtered.length - limit)
        : filtered;
  }

  @override
  Future<List<ChatMessage>> searchMessages(
    String conversationId,
    String query, {
    int limit = 200,
  }) async {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return const [];
    final list = _messages[conversationId];
    if (list == null || list.isEmpty) return const [];
    final matches = list
        .where((m) =>
            m.kind == MessageKind.text && m.body.toLowerCase().contains(q))
        .toList()
      ..sort((a, b) => b.serverTs.compareTo(a.serverTs));
    return matches.length > limit ? matches.sublist(0, limit) : matches;
  }

  @override
  Future<void> upsertConversation(Conversation conversation) async {
    _convos[conversation.id] = _ConvoRow(
      peerUsername: conversation.peerUsername,
      peerAccountId: conversation.peerAccountId,
      peerDeviceId: conversation.peerDeviceId,
      peerIdentityPubKey: List<int>.from(conversation.peerIdentityPubKey),
      peerX25519PubKey: List<int>.from(conversation.peerX25519PubKey),
      unreadCount: conversation.unreadCount,
      verified: conversation.verified,
      cryptoMode: conversation.cryptoMode,
      pending: conversation.pending,
      pinned: conversation.pinned,
      pinnedEnvelopeId: conversation.pinnedEnvelopeId,
      muted: conversation.muted,
      archived: conversation.archived,
      blocked: conversation.blocked,
      disappearingTtl: conversation.disappearingTtl,
    );
    _kinds[conversation.id] = conversation.kind;
    final existing = _groupFields[conversation.id];
    _groupFields[conversation.id] = _GroupFields(
      groupName: conversation.groupName ?? existing?.groupName,
      mlsEpoch: conversation.mlsEpoch ?? existing?.mlsEpoch,
    );
  }

  @override
  Future<void> upsertConversationWithMessages(
      Conversation conversation, List<ChatMessage> messages) async {
    // No transactions to save here — the in-memory store commits nothing —
    // so this just has to be equivalent to the two calls it replaces.
    await upsertConversation(conversation);
    await upsertMessages(conversation.id, messages);
  }

  @override
  Future<void> deleteConversation(String conversationId) async {
    _convos.remove(conversationId);
    _messages.remove(conversationId);
    _members.remove(conversationId);
    _kinds.remove(conversationId);
    _groupFields.remove(conversationId);
  }

  @override
  Future<void> clearMessagesForConversation(String conversationId) async {
    _messages.remove(conversationId);
  }

  @override
  Future<ChatMessage?> getMessage(String envelopeId) async {
    for (final list in _messages.values) {
      for (final m in list) {
        if (m.envelopeId == envelopeId) return m;
      }
    }
    return null;
  }

  @override
  Future<bool> hasMessageWithClientId(
    String conversationId,
    String senderDeviceId,
    String clientMsgId,
  ) async {
    final list = _messages[conversationId];
    if (list == null) return false;
    return list.any((m) =>
        m.senderDeviceId == senderDeviceId && m.clientMsgId == clientMsgId);
  }

  @override
  Future<void> upsertMessages(String conversationId, List<ChatMessage> messages) async {
    final list = _messages.putIfAbsent(conversationId, () => <ChatMessage>[]);
    for (final m in messages) {
      final i = list.indexWhere((x) => x.envelopeId == m.envelopeId);
      if (i >= 0) {
        list[i] = m;
      } else {
        list.add(m);
      }
    }
  }

  @override
  Future<void> deleteMessage(String envelopeId) async {
    for (final list in _messages.values) {
      list.removeWhere((m) => m.envelopeId == envelopeId);
    }
  }

  @override
  Future<void> trimMessages(String conversationId, {required int keep}) async {
    final list = _messages[conversationId];
    if (list == null || list.length <= keep) return;
    list.sort((a, b) => a.serverTs.compareTo(b.serverTs));
    list.removeRange(0, list.length - keep);
  }

  @override
  Future<void> clearAll() async {
    _convos.clear();
    _messages.clear();
    _cryptoStates.clear();
    _members.clear();
    _kinds.clear();
    _groupFields.clear();
    _deletedGroups.clear();
  }

  @override
  Future<void> deleteFile() async {
    _convos.clear();
    _messages.clear();
    _cryptoStates.clear();
    _members.clear();
    _kinds.clear();
    _groupFields.clear();
    _deletedGroups.clear();
    _open = false;
  }

  @override
  Future<int> deleteMessagesPastLocalRetention(
      DateTime now, int? globalTtlSeconds) async {
    var removed = 0;
    for (final entry in _messages.entries) {
      final override = _convos[entry.key]?.disappearingTtl ?? -1;
      final effSecs = override > 0 ? override : globalTtlSeconds;
      if (effSecs == null) continue; // no local retention for this conversation
      final list = entry.value;
      final before = list.length;
      list.removeWhere(
          (m) => !now.isBefore(m.serverTs.add(Duration(seconds: effSecs))));
      removed += before - list.length;
    }
    return removed;
  }

  @override
  Future<int> deleteExpiredMessages(DateTime now) async {
    var removed = 0;
    for (final entry in _messages.entries) {
      final list = entry.value;
      final before = list.length;
      list.removeWhere(
          (m) => m.expiresAt != null && !now.isBefore(m.expiresAt!));
      removed += before - list.length;
    }
    return removed;
  }

  @override
  Future<ConversationCryptoState?> loadConversationCryptoState(
    String conversationId, {
    String peerDeviceId = '',
  }) async {
    return _cryptoStates[_cryptoKey(conversationId, peerDeviceId)];
  }

  @override
  Future<void> saveConversationCryptoState(ConversationCryptoState state) async {
    _cryptoStates[_cryptoKey(state.conversationId, state.peerDeviceId)] = state;
  }

  @override
  Future<void> deleteConversationCryptoState(String conversationId) async {
    // Drop every peer-device pair for the conversation.
    final prefix = '$conversationId ';
    _cryptoStates.removeWhere((k, _) => k.startsWith(prefix));
  }

  static String _cryptoKey(String conversationId, String peerDeviceId) =>
      '$conversationId $peerDeviceId';

  @override
  Future<void> upsertGroupMembers(
    String conversationId,
    List<GroupMember> members,
  ) async {
    _members[conversationId] = List.of(members);
  }

  @override
  Future<List<GroupMember>> getGroupMembers(String conversationId) async {
    return List.unmodifiable(_members[conversationId] ?? const []);
  }

  @override
  Future<void> deleteGroupMember(String conversationId, String deviceId) async {
    _members[conversationId]?.removeWhere((m) => m.deviceId == deviceId);
  }

  @override
  Future<void> deleteGroupMembersForConversation(String conversationId) async {
    _members.remove(conversationId);
  }

  @override
  Future<void> updateConversationGroupFields(
    String conversationId, {
    String? groupName,
    int? mlsEpoch,
  }) async {
    final existing = _groupFields[conversationId] ?? _GroupFields();
    _groupFields[conversationId] = _GroupFields(
      groupName: groupName ?? existing.groupName,
      mlsEpoch: mlsEpoch ?? existing.mlsEpoch,
    );
  }

  @override
  Future<void> markGroupDeleted(String conversationId) async {
    _deletedGroups.add(conversationId);
  }

  @override
  Future<void> clearGroupDeleted(String conversationId) async {
    _deletedGroups.remove(conversationId);
  }

  @override
  Future<Set<String>> loadDeletedGroupIds() async => Set.of(_deletedGroups);
}

class _ConvoRow {
  _ConvoRow({
    required this.peerUsername,
    required this.peerAccountId,
    required this.peerDeviceId,
    this.pinned = false,
    this.pinnedEnvelopeId,
    this.muted = false,
    this.archived = false,
    this.blocked = false,
    this.disappearingTtl = -1,
    required this.peerIdentityPubKey,
    required this.peerX25519PubKey,
    required this.unreadCount,
    required this.verified,
    required this.cryptoMode,
    required this.pending,
  });
  final String peerUsername;
  final String peerAccountId;
  final String peerDeviceId;
  final List<int> peerIdentityPubKey;
  final List<int> peerX25519PubKey;
  final int unreadCount;
  final bool verified;
  final CryptoMode cryptoMode;
  final bool pending;
  final bool pinned;
  final String? pinnedEnvelopeId;
  final bool muted;
  final bool archived;
  final bool blocked;
  final int disappearingTtl;
}

class _GroupFields {
  _GroupFields({this.groupName, this.mlsEpoch});
  final String? groupName;
  final int? mlsEpoch;
}
