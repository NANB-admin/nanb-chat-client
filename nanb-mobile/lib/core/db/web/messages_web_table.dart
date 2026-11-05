import 'models/web_row.dart';
import 'models/web_table_names.dart';
import 'web_journal.dart';
import 'web_table.dart';

/// The `messages` table plus a conversation_id index (the equivalent of
/// `idx_messages_convo_ts`), so per-conversation reads and deletes don't scan
/// every message.
class MessagesWebTable extends WebTable {
  MessagesWebTable(WebJournal journal)
      : super(WebTableNames.messages, journal);

  final Map<String, Map<String, WebRow>> _byConversation = {};

  /// Rows of [conversationId] in insertion (rowid) order.
  Iterable<WebRow> inConversation(String conversationId) =>
      _byConversation[conversationId]?.values ?? const <WebRow>[];

  Iterable<String> get conversationIds => _byConversation.keys;

  @override
  void onAdded(String key, WebRow row) {
    final convo = row['conversation_id'] as String;
    (_byConversation[convo] ??= <String, WebRow>{})[key] = row;
  }

  @override
  void onRemoved(String key, WebRow row) {
    final convo = row['conversation_id'] as String;
    final bucket = _byConversation[convo];
    if (bucket == null) return;
    bucket.remove(key);
    if (bucket.isEmpty) _byConversation.remove(convo);
  }
}
