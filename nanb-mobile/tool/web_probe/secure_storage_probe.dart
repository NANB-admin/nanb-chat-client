// Dev-only probe: exercises SecureStorageWeb in a real browser without the
// Flutter engine. Compile with `dart compile js` and open in Chrome; results
// are written into the page body. Not part of the shipped app.
import 'dart:js_interop';

import 'package:nanb_chat/core/secure_storage/secure_storage_web.dart';
import 'package:nanb_chat/core/secure_storage/web/idb_request_future.dart';
import 'package:web/web.dart' as web;

final List<String> _lines = [];

void _report(String name, bool ok, [String detail = '']) {
  _lines.add('${ok ? 'PASS' : 'FAIL'} $name $detail');
  web.document.body!.textContent = _lines.join('\n');
}

Future<String?> _raw(String dbName, String key) async {
  final request = web.window.indexedDB.open(dbName, 1);
  final db = await idbRequestFuture(request) as web.IDBDatabase;
  final stored = await idbRequestFuture(
    db.transaction('values'.toJS, 'readonly').objectStore('values').get(key.toJS),
  );
  db.close();
  if (stored == null || stored.isUndefinedOrNull) return null;
  return (stored as JSString).toDart;
}

Future<void> main() async {
  final stamp = DateTime.now().microsecondsSinceEpoch;
  try {
    final a = SecureStorageWeb(databaseName: 'probe-a-$stamp');
    _report('missing key is null', await a.getString('nope') == null);

    await a.putString('seed', 'correct horse battery staple');
    _report('round trip', await a.getString('seed') == 'correct horse battery staple');

    await a.putString('name', 'Zoë — 你好 🔐');
    _report('non-ascii round trip', await a.getString('name') == 'Zoë — 你好 🔐');

    await a.putString('seed', 'two');
    _report('overwrite', await a.getString('seed') == 'two');

    await a.delete('seed');
    _report('delete removes key', await a.getString('seed') == null);
    _report('delete keeps others', await a.getString('name') == 'Zoë — 你好 🔐');

    final b = SecureStorageWeb(databaseName: 'probe-a-$stamp');
    _report('persists across instances', await b.getString('name') == 'Zoë — 你好 🔐');

    final c = SecureStorageWeb(databaseName: 'probe-c-$stamp');
    _report('databases isolated', await c.getString('name') == null);

    await a.putString('s', 'super-secret-value');
    final raw1 = await _raw('probe-a-$stamp', 's');
    _report('not stored as plaintext', raw1 != null && !raw1.contains('super-secret-value'));

    await a.putString('s', 'super-secret-value');
    final raw2 = await _raw('probe-a-$stamp', 's');
    _report('fresh IV each write', raw1 != raw2);

    await a.clear();
    _report('clear', await a.getString('name') == null);
    _lines.add('DONE');
    web.document.body!.textContent = _lines.join('\n');
  } catch (e, st) {
    _lines.add('ERROR $e\n$st');
    web.document.body!.textContent = _lines.join('\n');
  }
}
