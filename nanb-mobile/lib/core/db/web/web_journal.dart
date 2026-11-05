import 'models/web_db_write.dart';
import 'models/web_row.dart';
import 'web_table.dart';
import 'web_write_queue.dart';

/// Records every table mutation made inside a transaction: an undo log (for
/// all-or-nothing rollback of the in-memory tables) and the write-through
/// entries to hand to the [WebWriteQueue] on commit.
class WebJournal {
  WebJournal(this._queue);

  final WebWriteQueue _queue;
  final List<_Undo> _undo = [];
  final List<WebDbWrite> _writes = [];
  int _depth = 0;

  /// Called by [WebTable] after each in-memory change.
  void record(WebTable table, String key, WebRow? before, WebRow? after) {
    final write = WebDbWrite(table.name, key, after);
    if (_depth == 0) {
      _queue.enqueue([write]);
      return;
    }
    _undo.add(_Undo(table, key, before));
    _writes.add(write);
  }

  /// Runs [body] atomically: if it throws, every table change it made is undone
  /// and nothing reaches the store; otherwise its writes are queued together.
  /// Nested calls join the outer transaction.
  T transact<T>(T Function() body) {
    if (_depth > 0) return body();
    _depth = 1;
    try {
      final result = body();
      _depth = 0;
      _queue.enqueue(_writes);
      _clearLogs();
      return result;
    } catch (_) {
      _depth = 0;
      for (final u in _undo.reversed) {
        u.table.restore(u.key, u.before);
      }
      _clearLogs();
      rethrow;
    }
  }

  void _clearLogs() {
    _undo.clear();
    _writes.clear();
  }
}

class _Undo {
  _Undo(this.table, this.key, this.before);
  final WebTable table;
  final String key;
  final WebRow? before;
}
