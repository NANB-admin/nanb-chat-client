import 'web_row.dart';

/// One persisted mutation: put [row] under ([table], [key]), or delete that
/// entry when [row] is null.
class WebDbWrite {
  const WebDbWrite(this.table, this.key, this.row);

  final String table;
  final String key;

  /// The new row, or null for a delete.
  final WebRow? row;

  bool get isDelete => row == null;
}
