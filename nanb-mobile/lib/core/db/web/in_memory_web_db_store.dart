import 'dart:convert';

import 'models/web_db_snapshot.dart';
import 'models/web_db_write.dart';
import 'models/web_row.dart';
import 'web_db_store.dart';

/// A [WebDbStore] held in RAM, for tests. Rows are pushed through a JSON round
/// trip on the way in and out, so (like a real backend) it only ever hands back
/// JSON-shaped values and never aliases the database's live rows.
class InMemoryWebDbStore implements WebDbStore {
  final WebDbSnapshot _data = {};

  /// Number of [applyWrites] calls received — lets tests assert batching.
  int applyCount = 0;

  /// When set, [applyWrites] throws it (to simulate a failing backend).
  Object? failWritesWith;

  /// Number of rows currently persisted, across all tables.
  int get rowCount =>
      _data.values.fold(0, (sum, table) => sum + table.length);

  /// The persisted row at ([table], [key]), or null.
  WebRow? rowAt(String table, String key) => _data[table]?[key];

  @override
  Future<WebDbSnapshot> loadAll() async {
    final out = <String, Map<String, WebRow>>{};
    _data.forEach((table, rows) {
      out[table] = {for (final e in rows.entries) e.key: _copy(e.value)};
    });
    return out;
  }

  @override
  Future<void> applyWrites(List<WebDbWrite> writes) async {
    final failure = failWritesWith;
    if (failure != null) throw failure;
    applyCount++;
    for (final w in writes) {
      final table = _data.putIfAbsent(w.table, () => <String, WebRow>{});
      final row = w.row;
      if (row == null) {
        table.remove(w.key);
      } else {
        table[w.key] = _copy(row);
      }
    }
  }

  @override
  Future<void> clear() async {
    _data.clear();
  }

  @override
  Future<void> close() async {}

  @override
  Future<void> destroy() async {
    _data.clear();
  }

  WebRow _copy(WebRow row) =>
      Map<String, Object?>.from(jsonDecode(jsonEncode(row)) as Map<String, Object?>);
}
