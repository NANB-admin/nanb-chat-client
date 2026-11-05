import '../../../features/chat/models/chat_message.dart';
import '../../../features/chat/models/conversation.dart';
import '../../../features/chat/models/group_member.dart';
import '../../crypto/conversation_crypto_state.dart';
import '../app_database.dart';
import 'conversation_store.dart';
import 'crypto_state_store.dart';
import 'deleted_group_store.dart';
import 'group_member_store.dart';
import 'message_store.dart';
import 'messages_web_table.dart';
import 'models/web_db_snapshot.dart';
import 'models/web_table_names.dart';
import 'web_db_store.dart';
import 'web_journal.dart';
import 'web_table.dart';
import 'web_write_queue.dart';

/// Browser [AppDatabase]: the whole dataset lives in memory (one table per SQL
/// table, same semantics as `AppDatabaseImpl`) and every committed change is
/// written through, batched, to a [WebDbStore] (IndexedDB in production).
///
/// Every mutating method runs as one atomic unit: if it throws midway, the
/// in-memory tables are rolled back and nothing is persisted. Like the SQL
/// implementation, calls made while the database is not open are harmless
/// no-ops that return empty results.
class AppDatabaseWeb implements AppDatabase {
  AppDatabaseWeb({required WebDbStore store, Duration? flushDelay})
      : _store = store {
    _queue = flushDelay == null
        ? WebWriteQueue(store)
        : WebWriteQueue(store, delay: flushDelay);
    _journal = WebJournal(_queue);
    _conversationsTable = WebTable(WebTableNames.conversations, _journal);
    _messagesTable = MessagesWebTable(_journal);
    _membersTable = WebTable(WebTableNames.groupMembers, _journal);
    _cryptoTable = WebTable(WebTableNames.cryptoStates, _journal);
    _deletedTable = WebTable(WebTableNames.deletedGroups, _journal);
    _conversations = ConversationStore(_conversationsTable);
    _messages = MessageStore(_messagesTable);
    _members = GroupMemberStore(_membersTable);
    _crypto = CryptoStateStore(_cryptoTable);
    _deleted = DeletedGroupStore(_deletedTable);
  }

  final WebDbStore _store;
  late final WebWriteQueue _queue;
  late final WebJournal _journal;
  late final WebTable _conversationsTable;
  late final MessagesWebTable _messagesTable;
  late final WebTable _membersTable;
  late final WebTable _cryptoTable;
  late final WebTable _deletedTable;
  late final ConversationStore _conversations;
  late final MessageStore _messages;
  late final GroupMemberStore _members;
  late final CryptoStateStore _crypto;
  late final DeletedGroupStore _deleted;

  bool _open = false;

  @override
  bool get isOpen => _open;

  /// Waits until every committed change has reached the [WebDbStore].
  Future<void> flush() => _queue.flush();

  /// Runs [body] atomically against the tables: all-or-nothing in memory, and
  /// persisted as one batch on success. Exposed so multi-step changes (and
  /// tests) share the exact mechanism the AppDatabase methods use.
  T runInTransaction<T>(T Function() body) => _journal.transact(body);

  @override
  Future<void> open({
    required String masterKeyHex,
    bool recreateIfUnreadable = false,
  }) async {
    if (_open) return;
    WebDbSnapshot snapshot;
    try {
      snapshot = await _store.loadAll();
    } on WebDbUnreadableException catch (e) {
      if (!recreateIfUnreadable) {
        throw DatabaseUnreadableException('indexeddb', e);
      }
      await _store.destroy();
      snapshot = await _store.loadAll();
    }
    _hydrate(snapshot);
    _open = true;
  }

  void _hydrate(WebDbSnapshot snapshot) {
    final tables = <String, WebTable>{
      WebTableNames.conversations: _conversationsTable,
      WebTableNames.messages: _messagesTable,
      WebTableNames.groupMembers: _membersTable,
      WebTableNames.cryptoStates: _cryptoTable,
      WebTableNames.deletedGroups: _deletedTable,
    };
    tables.forEach((name, table) {
      table.dropAll();
      snapshot[name]?.forEach(table.load);
    });
  }

  @override
  Future<void> close() async {
    if (!_open) return;
    _open = false;
    await _queue.flush();
    await _store.close();
    for (final t in _allTables) {
      t.dropAll();
    }
  }

  List<WebTable> get _allTables => [
        _conversationsTable,
        _messagesTable,
        _membersTable,
        _cryptoTable,
        _deletedTable,
      ];

  @override
  Future<List<Conversation>> loadConversations({
    int messagesPerConversation = 50,
  }) async {
    if (!_open) return const [];
    return _conversations.loadAll(_messages, _members, messagesPerConversation);
  }

  @override
  Future<List<ChatMessage>> loadMessages(
    String conversationId, {
    required int limit,
    int? beforeServerTsMs,
  }) async {
    if (!_open) return const [];
    return _messages.page(conversationId,
        limit: limit, beforeServerTsMs: beforeServerTsMs);
  }

  @override
  Future<List<ChatMessage>> searchMessages(
    String conversationId,
    String query, {
    int limit = 200,
  }) async {
    if (!_open) return const [];
    return _messages.search(conversationId, query, limit);
  }

  @override
  Future<void> upsertConversation(Conversation conversation) async {
    if (!_open) return;
    runInTransaction(() => _conversations.upsert(conversation));
  }

  @override
  Future<void> upsertConversationWithMessages(
      Conversation conversation, List<ChatMessage> messages) async {
    if (!_open) return;
    runInTransaction(() {
      _conversations.upsert(conversation);
      _messages.upsertAll(conversation.id, messages);
    });
  }

  @override
  Future<void> deleteConversation(String conversationId) async {
    if (!_open) return;
    runInTransaction(() {
      _members.deleteForConversation(conversationId);
      _messages.deleteForConversation(conversationId);
      _conversations.delete(conversationId);
    });
  }

  @override
  Future<void> clearMessagesForConversation(String conversationId) async {
    if (!_open) return;
    runInTransaction(() => _messages.deleteForConversation(conversationId));
  }

  @override
  Future<ChatMessage?> getMessage(String envelopeId) async {
    if (!_open) return null;
    return _messages.get(envelopeId);
  }

  @override
  Future<bool> hasMessageWithClientId(
    String conversationId,
    String senderDeviceId,
    String clientMsgId,
  ) async {
    if (!_open) return false;
    return _messages.hasClientId(conversationId, senderDeviceId, clientMsgId);
  }

  @override
  Future<void> upsertMessages(
      String conversationId, List<ChatMessage> messages) async {
    if (!_open) return;
    runInTransaction(() => _messages.upsertAll(conversationId, messages));
  }

  @override
  Future<void> deleteMessage(String envelopeId) async {
    if (!_open) return;
    runInTransaction(() => _messages.delete(envelopeId));
  }

  @override
  Future<void> trimMessages(String conversationId, {required int keep}) async {
    if (!_open) return;
    runInTransaction(() => _messages.trim(conversationId, keep));
  }

  @override
  Future<void> clearAll() async {
    if (!_open) return;
    runInTransaction(() {
      for (final t in _allTables) {
        for (final key in t.entries.map((e) => e.key).toList()) {
          t.remove(key);
        }
      }
    });
  }

  @override
  Future<void> deleteFile() async {
    _open = false;
    for (final t in _allTables) {
      t.dropAll();
    }
    await _queue.clearAll(destroy: true);
  }

  @override
  Future<int> deleteMessagesPastLocalRetention(
      DateTime now, int? globalTtlSeconds) async {
    if (!_open) return 0;
    if (globalTtlSeconds == null && !_conversations.anyDisappearingOverride) {
      return 0;
    }
    return runInTransaction(() => _messages.deletePastRetention(
          now.toUtc().millisecondsSinceEpoch,
          globalTtlSeconds,
          _conversations.disappearingTtl,
        ));
  }

  @override
  Future<int> deleteExpiredMessages(DateTime now) async {
    if (!_open) return 0;
    return runInTransaction(
        () => _messages.deleteExpired(now.toUtc().millisecondsSinceEpoch));
  }

  @override
  Future<ConversationCryptoState?> loadConversationCryptoState(
    String conversationId, {
    String peerDeviceId = '',
  }) async {
    if (!_open) return null;
    return _crypto.load(conversationId, peerDeviceId);
  }

  @override
  Future<void> saveConversationCryptoState(
      ConversationCryptoState state) async {
    if (!_open) return;
    runInTransaction(() => _crypto.save(state));
  }

  @override
  Future<void> deleteConversationCryptoState(String conversationId) async {
    if (!_open) return;
    runInTransaction(() => _crypto.deleteForConversation(conversationId));
  }

  @override
  Future<void> upsertGroupMembers(
    String conversationId,
    List<GroupMember> members,
  ) async {
    if (!_open) return;
    runInTransaction(() => _members.replaceAll(conversationId, members));
  }

  @override
  Future<List<GroupMember>> getGroupMembers(String conversationId) async {
    if (!_open) return const [];
    return _members.forConversation(conversationId);
  }

  @override
  Future<void> deleteGroupMember(String conversationId, String deviceId) async {
    if (!_open) return;
    runInTransaction(() => _members.delete(conversationId, deviceId));
  }

  @override
  Future<void> deleteGroupMembersForConversation(String conversationId) async {
    if (!_open) return;
    runInTransaction(() => _members.deleteForConversation(conversationId));
  }

  @override
  Future<void> updateConversationGroupFields(
    String conversationId, {
    String? groupName,
    int? mlsEpoch,
  }) async {
    if (!_open) return;
    runInTransaction(() => _conversations.updateGroupFields(conversationId,
        groupName: groupName, mlsEpoch: mlsEpoch));
  }

  @override
  Future<void> markGroupDeleted(String conversationId) async {
    if (!_open) return;
    runInTransaction(() => _deleted.mark(
        conversationId, DateTime.now().toUtc().millisecondsSinceEpoch));
  }

  @override
  Future<void> clearGroupDeleted(String conversationId) async {
    if (!_open) return;
    runInTransaction(() => _deleted.clear(conversationId));
  }

  @override
  Future<Set<String>> loadDeletedGroupIds() async {
    if (!_open) return <String>{};
    return _deleted.ids();
  }
}
