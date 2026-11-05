import 'web_row.dart';

/// Everything a `WebDbStore` holds: table name -> (row key -> row).
typedef WebDbSnapshot = Map<String, Map<String, WebRow>>;
