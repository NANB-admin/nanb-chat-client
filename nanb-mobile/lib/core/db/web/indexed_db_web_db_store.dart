import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'idb_requests.dart';
import 'models/web_db_snapshot.dart';
import 'models/web_db_write.dart';
import 'models/web_row.dart';
import 'web_crypto_row_cipher.dart';
import 'web_db_store.dart';

/// Browser [WebDbStore]: every row is one IndexedDB record whose value is the
/// row's JSON sealed with AES-GCM. The CryptoKey is generated once as
/// NON-EXTRACTABLE and kept (structured-cloned) in a second object store of the
/// same database, so the raw key bytes never exist in script-visible memory or
/// on disk — an IndexedDB dump alone yields only ciphertext.
///
/// Honest limit: the browser origin can still ASK the key to decrypt, so this
/// protects data at rest against disk/profile theft, not against code running
/// inside the page.
class IndexedDbWebDbStore implements WebDbStore {
  IndexedDbWebDbStore({this.databaseName = 'nanb_chat_db'});

  final String databaseName;

  static const _rowsStore = 'rows';
  static const _keysStore = 'keys';
  static const _keyId = 'row-key';
  static const _separator = '\u0000';

  web.IDBDatabase? _db;
  WebCryptoRowCipher? _cipher;

  @override
  Future<WebDbSnapshot> loadAll() async {
    final db = await _open();
    final cipher = _cipher = await _loadOrCreateCipher(db);
    final tx = db.transaction(_rowsStore.toJS, 'readonly');
    final store = tx.objectStore(_rowsStore);
    final keysReq = IdbRequests.result(store.getAllKeys());
    final valuesReq = IdbRequests.result(store.getAll());
    final keys = (await keysReq as JSArray<JSAny?>).toDart;
    final values = (await valuesReq as JSArray<JSAny?>).toDart;
    final snapshot = <String, Map<String, WebRow>>{};
    try {
      for (var i = 0; i < keys.length; i++) {
        final id = (keys[i]! as JSString).toDart;
        final sealed = (values[i]! as JSUint8Array).toDart;
        final json = await cipher.open(id, sealed);
        final split = id.indexOf(_separator);
        final table = id.substring(0, split);
        final key = id.substring(split + 1);
        (snapshot[table] ??= <String, WebRow>{})[key] =
            Map<String, Object?>.from(jsonDecode(json) as Map<String, Object?>);
      }
    } catch (e) {
      throw WebDbUnreadableException(e);
    }
    return snapshot;
  }

  @override
  Future<void> applyWrites(List<WebDbWrite> writes) async {
    if (writes.isEmpty) return;
    final db = await _open();
    final cipher = _cipher ?? (_cipher = await _loadOrCreateCipher(db));
    // Encrypt BEFORE opening the transaction: IndexedDB auto-commits a
    // transaction that sits idle across a non-IndexedDB await.
    final sealed = <String, Uint8List?>{};
    for (final w in writes) {
      final id = '${w.table}$_separator${w.key}';
      final row = w.row;
      sealed[id] = row == null ? null : await cipher.seal(id, jsonEncode(row));
    }
    final tx = db.transaction(_rowsStore.toJS, 'readwrite');
    final committed = IdbRequests.committed(tx);
    final store = tx.objectStore(_rowsStore);
    sealed.forEach((id, bytes) {
      if (bytes == null) {
        store.delete(id.toJS);
      } else {
        store.put(bytes.toJS, id.toJS);
      }
    });
    await committed;
  }

  @override
  Future<void> clear() async {
    final db = await _open();
    final tx = db.transaction(_rowsStore.toJS, 'readwrite');
    final committed = IdbRequests.committed(tx);
    tx.objectStore(_rowsStore).clear();
    await committed;
  }

  @override
  Future<void> close() async {
    _db?.close();
    _db = null;
    _cipher = null;
  }

  @override
  Future<void> destroy() async {
    await close();
    final request = web.window.indexedDB.deleteDatabase(databaseName);
    await IdbRequests.result(request);
  }

  Future<web.IDBDatabase> _open() async {
    final existing = _db;
    if (existing != null) return existing;
    final request = web.window.indexedDB.open(databaseName, 1);
    request.onupgradeneeded = ((web.Event _) {
      final db = request.result! as web.IDBDatabase;
      db.createObjectStore(_rowsStore);
      db.createObjectStore(_keysStore);
    }).toJS;
    final db = await IdbRequests.result(request) as web.IDBDatabase;
    return _db = db;
  }

  /// Reads the stored non-extractable key, or creates + stores one. The get and
  /// put share one readwrite transaction so two tabs racing at first run agree
  /// on a single key.
  Future<WebCryptoRowCipher> _loadOrCreateCipher(web.IDBDatabase db) async {
    final candidate = await WebCryptoRowCipher.generateKey();
    final tx = db.transaction(_keysStore.toJS, 'readwrite');
    final committed = IdbRequests.committed(tx);
    final store = tx.objectStore(_keysStore);
    final stored = await IdbRequests.result(store.get(_keyId.toJS));
    final web.CryptoKey key;
    if (stored == null) {
      store.put(candidate, _keyId.toJS);
      key = candidate;
    } else {
      key = stored as web.CryptoKey;
    }
    await committed;
    return WebCryptoRowCipher(key);
  }
}
