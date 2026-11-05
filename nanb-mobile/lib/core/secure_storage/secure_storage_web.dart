import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'secure_storage.dart';
import 'web/idb_request_future.dart';
import 'web/web_vault_cipher.dart';
import 'web/web_vault_key.dart';

/// Browser [SecureStorage]: each value is AES-GCM encrypted with a
/// non-extractable WebCrypto key and stored in IndexedDB.
///
/// Honest limits: a browser has no Keychain/Keystore. This protects against
/// someone copying the profile's files or reading storage out-of-band, but not
/// against script running on this origin while the page is open (it can ask the
/// browser to decrypt). The origin therefore must serve only this app, with a
/// strict Content-Security-Policy.
class SecureStorageWeb implements SecureStorage {
  SecureStorageWeb({String databaseName = 'nanb-secure'})
      : _databaseName = databaseName;

  static const String _valuesStore = 'values';

  final String _databaseName;
  Future<_Vault>? _vault;

  Future<_Vault> _open() => _vault ??= _openVault();

  Future<_Vault> _openVault() async {
    final request = web.window.indexedDB.open(_databaseName, 1);
    request.onupgradeneeded = ((web.Event _) {
      final db = request.result as web.IDBDatabase;
      db.createObjectStore(_valuesStore);
      db.createObjectStore(WebVaultKey.storeName);
    }).toJS;
    final db = await idbRequestFuture(request) as web.IDBDatabase;
    final key = await WebVaultKey(db).load();
    return _Vault(db, WebVaultCipher(key));
  }

  @override
  Future<String?> getString(String key) async {
    final vault = await _open();
    final stored = await idbRequestFuture(
      vault.db
          .transaction(_valuesStore.toJS, 'readonly')
          .objectStore(_valuesStore)
          .get(key.toJS),
    );
    if (stored == null || stored.isUndefinedOrNull) return null;
    return vault.cipher.decrypt((stored as JSString).toDart);
  }

  @override
  Future<void> putString(String key, String value) async {
    final vault = await _open();
    final encrypted = await vault.cipher.encrypt(value);
    final tx = vault.db.transaction(_valuesStore.toJS, 'readwrite');
    tx.objectStore(_valuesStore).put(encrypted.toJS, key.toJS);
    await idbTransactionDone(tx);
  }

  @override
  Future<void> delete(String key) async {
    final vault = await _open();
    final tx = vault.db.transaction(_valuesStore.toJS, 'readwrite');
    tx.objectStore(_valuesStore).delete(key.toJS);
    await idbTransactionDone(tx);
  }

  @override
  Future<void> clear() async {
    final vault = await _open();
    final tx = vault.db.transaction(_valuesStore.toJS, 'readwrite');
    tx.objectStore(_valuesStore).clear();
    await idbTransactionDone(tx);
  }
}

class _Vault {
  const _Vault(this.db, this.cipher);

  final web.IDBDatabase db;
  final WebVaultCipher cipher;
}
