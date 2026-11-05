import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// AES-256-GCM sealing of row values with a WebCrypto [web.CryptoKey]. Each
/// value gets a fresh random 96-bit IV (stored as the first 12 bytes of the
/// output) and is bound to its storage id as additional authenticated data, so
/// a ciphertext can't be moved to a different row undetected.
class WebCryptoRowCipher {
  WebCryptoRowCipher(this._key);

  final web.CryptoKey _key;

  static const _ivLength = 12;

  /// A fresh non-extractable AES-256-GCM key: its raw bytes can never be
  /// exported, not even by script running in this origin.
  static Future<web.CryptoKey> generateKey() async {
    final algorithm = {'name': 'AES-GCM', 'length': 256}.jsify()!;
    final usages = <JSString>['encrypt'.toJS, 'decrypt'.toJS].toJS;
    final key = await web.window.crypto.subtle
        .generateKey(algorithm, false, usages)
        .toDart;
    return key as web.CryptoKey;
  }

  Future<Uint8List> seal(String id, String plaintext) async {
    final iv = Uint8List(_ivLength);
    web.window.crypto.getRandomValues(iv.toJS);
    final cipher = await web.window.crypto.subtle
        .encrypt(_params(iv, id), _key,
            Uint8List.fromList(utf8.encode(plaintext)).toJS)
        .toDart;
    final body = (cipher as JSArrayBuffer).toDart.asUint8List();
    final out = Uint8List(_ivLength + body.length)
      ..setRange(0, _ivLength, iv)
      ..setRange(_ivLength, _ivLength + body.length, body);
    return out;
  }

  /// Throws if the bytes were tampered with, moved, or sealed under another key.
  Future<String> open(String id, Uint8List sealed) async {
    final iv = Uint8List.sublistView(sealed, 0, _ivLength);
    final body = Uint8List.sublistView(sealed, _ivLength);
    final plain = await web.window.crypto.subtle
        .decrypt(_params(iv, id), _key, body.toJS)
        .toDart;
    return utf8.decode((plain as JSArrayBuffer).toDart.asUint8List());
  }

  JSAny _params(Uint8List iv, String id) => {
        'name': 'AES-GCM',
        'iv': iv.toJS,
        'additionalData': Uint8List.fromList(utf8.encode(id)).toJS,
      }.jsify()!;
}
