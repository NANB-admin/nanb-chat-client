import 'dart:isolate';
import 'dart:math';

import 'package:cryptography/cryptography.dart';

/// AES-256-GCM symmetric encryption for media bytes (images, voice notes,
/// files). Each media object gets a fresh random key + nonce — the key is
/// then wrapped inside the (ratchet-encrypted) chat message body so the
/// server only sees opaque ciphertext for both the message AND the media.
///
/// Wire format on the encrypted blob: `[12-byte nonce][N-byte cipher][16-byte tag]`.
class MediaCipher {
  MediaCipher._();

  static final AesGcm _aead = AesGcm.with256bits();

  /// Encrypt `plaintext` with a freshly-generated 256-bit key + 96-bit
  /// nonce. Returns the wire-formatted ciphertext + the raw key (32 bytes).
  /// Caller must wrap the key inside a per-conversation encrypted message
  /// so the server never sees it.
  static Future<MediaEncryptResult> encrypt(List<int> plaintext) async {
    final key = _randomBytes(32);
    final nonce = _randomBytes(12);
    // AES-256-GCM over multi-MB media is CPU-heavy — run it on a background
    // isolate so the UI isolate doesn't jank for seconds per photo/video. The
    // captured inputs (all `List<int>`) and the returned wire bytes cross the
    // isolate boundary by copy; `_aead` is a static, so it lazily re-inits on
    // the spawned isolate rather than being captured.
    final wire = await Isolate.run(() async {
      final box = await _aead.encrypt(
        plaintext,
        secretKey: SecretKey(key),
        nonce: nonce,
      );
      return <int>[...nonce, ...box.cipherText, ...box.mac.bytes];
    });
    return MediaEncryptResult(ciphertext: wire, key: key);
  }

  /// Decrypt a media wire blob using the per-media key. Throws on tag
  /// mismatch (tampered or wrong key) or `FormatException` if the blob is
  /// shorter than nonce + tag.
  static Future<List<int>> decrypt({
    required List<int> ciphertext,
    required List<int> key,
  }) async {
    if (ciphertext.length < 12 + 16) {
      throw const FormatException('media: ciphertext too short');
    }
    final nonce = ciphertext.sublist(0, 12);
    final macStart = ciphertext.length - 16;
    final cipher = ciphertext.sublist(12, macStart);
    final macBytes = ciphertext.sublist(macStart);
    // Authenticate + decrypt off the UI isolate (see `encrypt`). A tag
    // mismatch throws inside the isolate and re-throws on this isolate.
    return Isolate.run(() async {
      final box = SecretBox(cipher, nonce: nonce, mac: Mac(macBytes));
      final pt = await _aead.decrypt(box, secretKey: SecretKey(key));
      return List<int>.from(pt);
    });
  }

  /// SHA-256 of arbitrary bytes — used for integrity verification on the
  /// receiving side: the sender hashes the *plaintext* and embeds the digest
  /// in the chat message; the receiver re-hashes after decrypt + compares.
  static Future<List<int>> sha256(List<int> bytes) async {
    // SHA-256 over the full media bytes off the UI isolate (see `encrypt`).
    return Isolate.run(() async {
      final hash = await Sha256().hash(bytes);
      return List<int>.from(hash.bytes);
    });
  }

  static List<int> _randomBytes(int n) {
    final rng = Random.secure();
    return List<int>.generate(n, (_) => rng.nextInt(256));
  }
}

/// Encrypt result — wire-formatted ciphertext + the fresh key. The key must
/// be transmitted to the recipient through the conversation ratchet, never
/// directly.
class MediaEncryptResult {
  const MediaEncryptResult({required this.ciphertext, required this.key});
  final List<int> ciphertext;
  final List<int> key;
}
