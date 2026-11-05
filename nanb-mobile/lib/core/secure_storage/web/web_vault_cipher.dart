import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// AES-256-GCM encrypt/decrypt of short strings with a WebCrypto [web.CryptoKey].
///
/// Wire format of an encrypted value: base64( iv[12] || ciphertext+tag ).
/// A fresh random IV is used for every encryption.
class WebVaultCipher {
  WebVaultCipher(this._key);

  static const int _ivLength = 12;

  final web.CryptoKey _key;

  Future<String> encrypt(String plaintext) async {
    final iv = Uint8List(_ivLength);
    web.window.crypto.getRandomValues(iv.toJS);
    final cipher = await web.window.crypto.subtle
        .encrypt(_algorithm(iv), _key, utf8.encode(plaintext).toJS)
        .toDart as JSArrayBuffer;
    final body = cipher.toDart.asUint8List();
    return base64.encode(Uint8List(iv.length + body.length)
      ..setRange(0, iv.length, iv)
      ..setRange(iv.length, iv.length + body.length, body));
  }

  Future<String> decrypt(String encoded) async {
    final raw = base64.decode(encoded);
    if (raw.length <= _ivLength) {
      throw const FormatException('vault value too short');
    }
    final iv = Uint8List.sublistView(raw, 0, _ivLength);
    final body = Uint8List.sublistView(raw, _ivLength);
    final plain = await web.window.crypto.subtle
        .decrypt(_algorithm(iv), _key, body.toJS)
        .toDart as JSArrayBuffer;
    return utf8.decode(plain.toDart.asUint8List());
  }

  JSAny _algorithm(Uint8List iv) =>
      {'name': 'AES-GCM', 'iv': iv.toJS}.jsify()!;
}
