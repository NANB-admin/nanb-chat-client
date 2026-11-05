import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/core/crypto/media_cipher.dart';

void main() {
  group('MediaCipher', () {
    test('encrypt + decrypt round-trips arbitrary bytes', () async {
      final plaintext = List<int>.generate(257, (i) => i & 0xff);
      final r = await MediaCipher.encrypt(plaintext);
      expect(r.key, hasLength(32));
      // Wire = 12 nonce + N cipher + 16 tag.
      expect(r.ciphertext.length, equals(12 + plaintext.length + 16));
      final pt = await MediaCipher.decrypt(ciphertext: r.ciphertext, key: r.key);
      expect(pt, equals(plaintext));
    });

    test('encrypt→decrypt round-trips a large buffer through the isolate path', () async {
      // A larger payload exercises the off-UI-isolate offload (the bytes are
      // copied to the spawned isolate and back) and confirms correctness is
      // preserved end-to-end through it.
      final plaintext = List<int>.generate(256 * 1024, (i) => (i * 31) & 0xff);
      final r = await MediaCipher.encrypt(plaintext);
      final pt = await MediaCipher.decrypt(ciphertext: r.ciphertext, key: r.key);
      expect(pt, equals(plaintext));
      // The digest computed on the background isolate matches a re-hash.
      final a = await MediaCipher.sha256(plaintext);
      final b = await MediaCipher.sha256(pt);
      expect(a, equals(b));
    });

    test('two encryptions of the same plaintext produce different ciphertexts', () async {
      final pt = List<int>.filled(64, 0xAA);
      final a = await MediaCipher.encrypt(pt);
      final b = await MediaCipher.encrypt(pt);
      expect(a.ciphertext, isNot(equals(b.ciphertext)));
      expect(a.key, isNot(equals(b.key)));
    });

    test('decrypt fails with wrong key', () async {
      final pt = [1, 2, 3];
      final r = await MediaCipher.encrypt(pt);
      final wrong = List<int>.from(r.key);
      wrong[0] ^= 0x01;
      expect(
        () => MediaCipher.decrypt(ciphertext: r.ciphertext, key: wrong),
        throwsA(anything),
      );
    });

    test('decrypt fails on tampered byte', () async {
      final r = await MediaCipher.encrypt([1, 2, 3, 4, 5, 6]);
      final tampered = List<int>.from(r.ciphertext);
      tampered[16] ^= 0x01; // flip a byte in the cipher portion
      expect(
        () => MediaCipher.decrypt(ciphertext: tampered, key: r.key),
        throwsA(anything),
      );
    });

    test('decrypt rejects ciphertext shorter than nonce + tag', () async {
      expect(
        () => MediaCipher.decrypt(
          ciphertext: List<int>.filled(20, 0),
          key: List<int>.filled(32, 0),
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('sha256 returns 32 bytes', () async {
      final h = await MediaCipher.sha256([1, 2, 3]);
      expect(h, hasLength(32));
    });

    test('sha256 of equal input is equal; different input is different', () async {
      final a = await MediaCipher.sha256([1, 2, 3]);
      final b = await MediaCipher.sha256([1, 2, 3]);
      final c = await MediaCipher.sha256([1, 2, 4]);
      expect(a, equals(b));
      expect(a, isNot(equals(c)));
    });
  });
}
