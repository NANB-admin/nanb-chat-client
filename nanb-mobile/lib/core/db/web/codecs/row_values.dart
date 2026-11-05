/// Small helpers for reading JSON-shaped [WebRow] values back into Dart types.
abstract final class RowValues {
  /// BLOB column -> `List<int>` (rows loaded from a store hold `List<dynamic>`).
  static List<int> intList(Object? blob) {
    if (blob is List) return List<int>.from(blob);
    return const [];
  }

  static bool flag(Object? v) => ((v as int?) ?? 0) == 1;

  static int boolInt(bool v) => v ? 1 : 0;

  static DateTime? msToUtc(Object? ms) => ms == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(ms as int, isUtc: true);
}
