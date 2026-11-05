import 'web_table.dart';

/// `deleted_groups` tombstone table logic.
class DeletedGroupStore {
  DeletedGroupStore(this._table);

  final WebTable _table;

  /// Idempotent; re-marking refreshes `deleted_at` (INSERT OR REPLACE).
  void mark(String conversationId, int nowMs) => _table.put(
      conversationId, {'conversation_id': conversationId, 'deleted_at': nowMs});

  void clear(String conversationId) => _table.remove(conversationId);

  Set<String> ids() => {
        for (final row in _table.rows) row['conversation_id'] as String,
      };
}
