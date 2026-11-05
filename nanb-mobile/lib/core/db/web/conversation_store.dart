import '../../../features/chat/models/conversation.dart';
import 'codecs/conversation_row_codec.dart';
import 'codecs/message_row_codec.dart';
import 'group_member_store.dart';
import 'message_store.dart';
import 'models/web_row.dart';
import 'web_table.dart';

/// `conversations` table logic.
class ConversationStore {
  ConversationStore(this._table);

  final WebTable _table;

  /// INSERT OR REPLACE of the whole row. Like the SQL implementation, a null
  /// `groupName` / `mlsEpoch` on [conversation] overwrites a stored value.
  void upsert(Conversation conversation) =>
      _table.put(conversation.id, ConversationRowCodec.encode(conversation));

  /// Removes the conversation row only; callers cascade to dependents.
  void delete(String conversationId) => _table.remove(conversationId);

  /// UPDATE of group_name / mls_epoch on an EXISTING row; a no-op when the row
  /// is absent or both values are null.
  void updateGroupFields(
    String conversationId, {
    String? groupName,
    int? mlsEpoch,
  }) {
    if (groupName == null && mlsEpoch == null) return;
    final row = _table.get(conversationId);
    if (row == null) return;
    final next = Map<String, Object?>.from(row);
    if (groupName != null) next['group_name'] = groupName;
    if (mlsEpoch != null) next['mls_epoch'] = mlsEpoch;
    _table.put(conversationId, next);
  }

  /// The per-conversation disappearing override in seconds, or 0 when the
  /// conversation is unknown (SQL: `COALESCE(c.disappearing_ttl, 0)`).
  int disappearingTtl(String conversationId) =>
      (_table.get(conversationId)?['disappearing_ttl'] as int?) ?? 0;

  bool get anyDisappearingOverride =>
      _table.rows.any((r) => ((r['disappearing_ttl'] as int?) ?? -1) > 0);

  /// Every conversation (in row order), each hydrated with its newest
  /// [messagesPerConversation] messages and its members.
  List<Conversation> loadAll(
    MessageStore messages,
    GroupMemberStore members,
    int messagesPerConversation,
  ) {
    final probe = messagesPerConversation + 1;
    final membersByConvo = members.byConversation();
    final out = <Conversation>[];
    for (final WebRow row in _table.rows) {
      final id = row['id'] as String;
      final bucket = messages.recentRows(id, probe);
      final hasMore = bucket.length == probe;
      final page = hasMore ? bucket.sublist(1) : bucket;
      out.add(ConversationRowCodec.decode(
        row,
        messages: page.map(MessageRowCodec.decode).toList(growable: false),
        hasMoreOlderMessages: hasMore,
        members: membersByConvo[id] ?? const [],
      ));
    }
    return out;
  }
}
