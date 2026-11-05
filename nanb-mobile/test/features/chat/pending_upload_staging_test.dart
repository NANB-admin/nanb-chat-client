import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/features/chat/pending_upload_staging.dart';

void main() {
  group('PendingUploadStagingImpl', () {
    late Directory tempBase;
    late PendingUploadStagingImpl staging;

    setUp(() async {
      tempBase = await Directory.systemTemp.createTemp('nanb_pending_test_');
      staging =
          PendingUploadStagingImpl(baseDirProvider: () async => tempBase);
    });

    tearDown(() async {
      if (tempBase.existsSync()) {
        await tempBase.delete(recursive: true);
      }
    });

    test('writes a ciphertext file and round-trips through decrypt', () async {
      const plaintext = [1, 2, 3, 4, 5, 0xff, 0x80, 0x00];
      final key = await staging.writeEncrypted(
        outboxId: 'env-A',
        plaintext: plaintext,
      );
      expect(key.length, 32);
      final out = await staging.readDecrypted(outboxId: 'env-A', key: key);
      expect(out, plaintext);
    });

    test('ciphertext on disk is not the plaintext', () async {
      const plaintext = [10, 20, 30, 40, 50];
      await staging.writeEncrypted(
        outboxId: 'env-A',
        plaintext: plaintext,
      );
      final file =
          File('${tempBase.path}/pending-uploads/env-A.bin');
      expect(file.existsSync(), isTrue);
      final raw = await file.readAsBytes();
      // Wire format = [12-byte nonce][N-byte cipher][16-byte tag]. For 5 plain
      // bytes the file is 12 + 5 + 16 = 33 bytes — meaningfully longer than
      // plaintext, and the cipher portion must not equal the plaintext.
      expect(raw.length, 12 + plaintext.length + 16);
      expect(raw.sublist(12, 12 + plaintext.length), isNot(equals(plaintext)));
    });

    test('returns null when the staging file is missing', () async {
      final out = await staging.readDecrypted(
        outboxId: 'never-staged',
        key: List<int>.filled(32, 0),
      );
      expect(out, isNull);
    });

    test('returns null when the key is wrong (GCM auth fails)', () async {
      const plaintext = [1, 2, 3];
      final key = await staging.writeEncrypted(
        outboxId: 'env-A',
        plaintext: plaintext,
      );
      final tampered = List<int>.from(key);
      tampered[0] = (tampered[0] + 1) & 0xff;
      final out =
          await staging.readDecrypted(outboxId: 'env-A', key: tampered);
      expect(out, isNull);
    });

    test('returns null when the ciphertext is truncated', () async {
      const plaintext = [1, 2, 3];
      final key = await staging.writeEncrypted(
        outboxId: 'env-A',
        plaintext: plaintext,
      );
      final file =
          File('${tempBase.path}/pending-uploads/env-A.bin');
      await file.writeAsBytes(const [0, 1, 2]); // shorter than nonce+tag
      final out = await staging.readDecrypted(outboxId: 'env-A', key: key);
      expect(out, isNull);
    });

    test('delete removes the staging file', () async {
      const plaintext = [1, 2, 3];
      await staging.writeEncrypted(outboxId: 'env-A', plaintext: plaintext);
      final file =
          File('${tempBase.path}/pending-uploads/env-A.bin');
      expect(file.existsSync(), isTrue);
      await staging.delete('env-A');
      expect(file.existsSync(), isFalse);
    });

    test('delete is a no-op when the file is already gone', () async {
      // Should complete without throwing.
      await staging.delete('never-staged');
    });

    test('listStagedOutboxIds reports every staged file', () async {
      await staging.writeEncrypted(outboxId: 'env-A', plaintext: const [1]);
      await staging.writeEncrypted(outboxId: 'env-B', plaintext: const [2]);
      await staging.writeEncrypted(outboxId: 'env-C', plaintext: const [3]);
      await staging.delete('env-B');
      final list = await staging.listStagedOutboxIds();
      expect(list.toSet(), {'env-A', 'env-C'});
    });

    test('per-upload keys differ across calls', () async {
      final keyA =
          await staging.writeEncrypted(outboxId: 'a', plaintext: const [0]);
      final keyB =
          await staging.writeEncrypted(outboxId: 'b', plaintext: const [0]);
      expect(keyA, isNot(equals(keyB)));
    });
  });
}
