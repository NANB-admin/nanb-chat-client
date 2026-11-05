import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/core/push/handled_envelope_log.dart';
import 'package:nanb_chat/core/secure_storage/secure_storage.dart';

void main() {
  group('HandledEnvelopeLog', () {
    test('mirrors a recorded id where the background isolate can read it',
        () async {
      final storage = SecureStorageInMemory();

      await HandledEnvelopeLog(storage: storage).record(['env-1']);

      expect(await HandledEnvelopeLog.read(storage), contains('env-1'));
    });

    test('records every id in a batch', () async {
      // Catchup acks in bursts, and each envelope has its own queued wakeup.
      final storage = SecureStorageInMemory();

      await HandledEnvelopeLog(storage: storage)
          .record(['env-1', 'env-2', 'env-3']);

      expect(await HandledEnvelopeLog.read(storage),
          containsAll(['env-1', 'env-2', 'env-3']));
    });

    test('drops the oldest ids once the window is full', () async {
      final storage = SecureStorageInMemory();
      final log = HandledEnvelopeLog(storage: storage, maxEntries: 2);

      await log.record(['old']);
      await log.record(['mid', 'new']);

      final mirrored = await HandledEnvelopeLog.read(storage);
      expect(mirrored, isNot(contains('old')));
      expect(mirrored, containsAll(['mid', 'new']));
    });

    test('keeps the window across a restart', () async {
      // A push queued before the app was killed is delivered after it
      // relaunches, so the previous run's ids still have to suppress it.
      final storage = SecureStorageInMemory();
      await HandledEnvelopeLog(storage: storage).record(['before-restart']);

      await HandledEnvelopeLog(storage: storage).record(['after-restart']);

      expect(await HandledEnvelopeLog.read(storage),
          containsAll(['before-restart', 'after-restart']));
    });

    test('recording the same id twice does not consume window space', () async {
      final storage = SecureStorageInMemory();
      final log = HandledEnvelopeLog(storage: storage, maxEntries: 2);

      await log.record(['a']);
      await log.record(['a']);
      await log.record(['b']);

      // 'a' would have been evicted by a duplicate entry.
      expect(await HandledEnvelopeLog.read(storage), containsAll(['a', 'b']));
    });

    test('an empty batch writes nothing', () async {
      final storage = SecureStorageInMemory();

      await HandledEnvelopeLog(storage: storage).record(const []);

      expect(await HandledEnvelopeLog.read(storage), isEmpty);
    });

    test('reads as empty when the mirror is unreadable', () async {
      // Must degrade to "show the banner", never to suppressing a real one.
      final storage = SecureStorageInMemory();
      await storage.putString(HandledEnvelopeLog.storageKey, 'not json');

      expect(await HandledEnvelopeLog.read(storage), isEmpty);
    });
  });
}
