// Browser smoke probe for IndexedDbWebDbStore. Built with `dart compile js`
// and driven by a headless browser; NOT part of the app (lives under tool/).
//
//   ?mode=write  -> persists a few rows
//   ?mode=read   -> loads them back
//   ?mode=wipe   -> destroys the database
//
// The outcome is printed as JSON into <pre id="out">.
import 'dart:convert';

import 'package:nanb_chat/core/db/web/indexed_db_web_db_store.dart';
import 'package:nanb_chat/core/db/web/models/web_db_write.dart';
import 'package:web/web.dart' as web;

const _secret = 'TOP-SECRET-PLAINTEXT-MARKER';

Future<void> main() async {
  final mode = Uri.base.queryParameters['mode'] ?? 'read';
  final out = web.document.getElementById('out')!;
  try {
    final store = IndexedDbWebDbStore(databaseName: 'nanb_probe_db');
    final result = <String, Object?>{'mode': mode};
    if (mode == 'write') {
      await store.loadAll();
      await store.applyWrites([
        const WebDbWrite('messages', 'm1', {'body': _secret, 'n': 1}),
        const WebDbWrite('messages', 'm2', {'body': 'second', 'n': 2}),
        const WebDbWrite('conversations', 'c1', {'id': 'c1'}),
        const WebDbWrite('messages', 'gone', {'body': 'x'}),
      ]);
      await store.applyWrites([const WebDbWrite('messages', 'gone', null)]);
    } else if (mode == 'read') {
      result['snapshot'] = await store.loadAll();
    } else if (mode == 'wipe') {
      await store.destroy();
    }
    await store.close();
    result['ok'] = true;
    out.textContent = jsonEncode(result);
  } catch (e) {
    out.textContent = jsonEncode({'ok': false, 'error': '$e'});
  }
}
