@TestOn('browser')
library;

import 'dart:js_interop';

import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/core/secure_storage/secure_storage_web.dart';
import 'package:nanb_chat/core/secure_storage/web/idb_request_future.dart';
import 'package:web/web.dart' as web;

int _counter = 0;

/// A fresh database name per test so tests never see each other's data.
String _freshDb() => 'test-vault-${DateTime.now().microsecondsSinceEpoch}-${_counter++}';

/// Reads the raw stored (still encrypted) value straight out of IndexedDB.
Future<String?> _rawStored(String dbName, String key) async {
  final request = web.window.indexedDB.open(dbName, 1);
  final db = await idbRequestFuture(request) as web.IDBDatabase;
  final stored = await idbRequestFuture(
    db.transaction('values'.toJS, 'readonly').objectStore('values').get(key.toJS),
  );
  db.close();
  if (stored == null || stored.isUndefinedOrNull) return null;
  return (stored as JSString).toDart;
}

void main() {
  group('SecureStorageWeb', () {
    test('returns null for a key that was never written', () async {
      final storage = SecureStorageWeb(databaseName: _freshDb());

      expect(await storage.getString('missing'), isNull);
    });

    test('returns what was written', () async {
      final storage = SecureStorageWeb(databaseName: _freshDb());
      await storage.putString('seed', 'correct horse battery staple');

      expect(await storage.getString('seed'), 'correct horse battery staple');
    });

    test('round-trips non-ASCII text', () async {
      final storage = SecureStorageWeb(databaseName: _freshDb());
      await storage.putString('name', 'Zoë — 你好 🔐');

      expect(await storage.getString('name'), 'Zoë — 你好 🔐');
    });

    test('overwrites an existing value', () async {
      final storage = SecureStorageWeb(databaseName: _freshDb());
      await storage.putString('k', 'one');
      await storage.putString('k', 'two');

      expect(await storage.getString('k'), 'two');
    });

    test('delete removes only that key', () async {
      final storage = SecureStorageWeb(databaseName: _freshDb());
      await storage.putString('a', '1');
      await storage.putString('b', '2');
      await storage.delete('a');

      expect(await storage.getString('a'), isNull);
      expect(await storage.getString('b'), '2');
    });

    test('clear removes every key', () async {
      final storage = SecureStorageWeb(databaseName: _freshDb());
      await storage.putString('a', '1');
      await storage.putString('b', '2');
      await storage.clear();

      expect(await storage.getString('a'), isNull);
      expect(await storage.getString('b'), isNull);
    });

    test('values survive a new instance over the same database', () async {
      final name = _freshDb();
      await SecureStorageWeb(databaseName: name).putString('k', 'persisted');

      expect(await SecureStorageWeb(databaseName: name).getString('k'), 'persisted');
    });

    test('databases with different names are isolated', () async {
      await SecureStorageWeb(databaseName: _freshDb()).putString('k', 'one');

      expect(await SecureStorageWeb(databaseName: _freshDb()).getString('k'), isNull);
    });

    test('does not store the plaintext in IndexedDB', () async {
      final name = _freshDb();
      await SecureStorageWeb(databaseName: name).putString('k', 'super-secret-value');

      final raw = await _rawStored(name, 'k');

      expect(raw, isNotNull);
      expect(raw, isNot(contains('super-secret-value')));
    });

    test('encrypts the same value differently each time (fresh IV)', () async {
      final name = _freshDb();
      final storage = SecureStorageWeb(databaseName: name);
      await storage.putString('k', 'same');
      final first = await _rawStored(name, 'k');
      await storage.putString('k', 'same');
      final second = await _rawStored(name, 'k');

      expect(first, isNot(equals(second)));
    });
  });
}
