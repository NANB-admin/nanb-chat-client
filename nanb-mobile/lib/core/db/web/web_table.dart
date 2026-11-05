import 'models/web_row.dart';
import 'web_journal.dart';

/// One in-memory table: rows by primary key, in insertion order. Replacing a
/// row moves it to the end — like SQLite's `INSERT OR REPLACE`, which assigns a
/// fresh rowid — so unordered scans match the SQL implementation.
///
/// Rows are treated as immutable; callers replace them rather than edit them.
class WebTable {
  WebTable(this.name, this._journal);

  final String name;
  final WebJournal _journal;
  final Map<String, WebRow> _rows = {};

  Iterable<WebRow> get rows => _rows.values;
  Iterable<MapEntry<String, WebRow>> get entries => _rows.entries;
  int get length => _rows.length;

  WebRow? get(String key) => _rows[key];

  /// INSERT OR REPLACE.
  void put(String key, WebRow row) {
    final before = _rawRemove(key);
    _rawAdd(key, row);
    _journal.record(this, key, before, row);
  }

  /// DELETE by key. Returns the removed row, or null if absent.
  WebRow? remove(String key) {
    final before = _rawRemove(key);
    if (before == null) return null;
    _journal.record(this, key, before, null);
    return before;
  }

  /// Un-journaled load of a persisted row (used at open).
  void load(String key, WebRow row) {
    _rawRemove(key);
    _rawAdd(key, row);
  }

  /// Un-journaled drop of every row (used at close / rollback of a reopen).
  void dropAll() {
    for (final key in _rows.keys.toList()) {
      _rawRemove(key);
    }
  }

  /// Un-journaled undo step: put [before] back, or delete the key if it was
  /// absent.
  void restore(String key, WebRow? before) {
    _rawRemove(key);
    if (before != null) _rawAdd(key, before);
  }

  /// Hook: [row] was just stored under [key].
  void onAdded(String key, WebRow row) {}

  /// Hook: [row] was just removed from under [key].
  void onRemoved(String key, WebRow row) {}

  WebRow? _rawRemove(String key) {
    final old = _rows.remove(key);
    if (old != null) onRemoved(key, old);
    return old;
  }

  void _rawAdd(String key, WebRow row) {
    _rows[key] = row;
    onAdded(key, row);
  }
}
