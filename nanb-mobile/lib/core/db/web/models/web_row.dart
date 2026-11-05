/// One table row, keyed by the SQL column names of `app_database_impl.dart`.
///
/// Values are restricted to what survives a JSON round trip (null, bool, int,
/// double, String, `List<int>` for BLOBs) so the same row can be held in memory,
/// encrypted, and persisted by any `WebDbStore`.
typedef WebRow = Map<String, Object?>;
