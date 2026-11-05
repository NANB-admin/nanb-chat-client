import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/core/secure_storage/secure_storage.dart';
import 'package:nanb_chat/features/chat/services/processed_envelope_log.dart';

void main() {
  group('ProcessedEnvelopeLog', () {
    test('reports an unseen envelope as not processed', () async {
      final log = ProcessedEnvelopeLog(storage: SecureStorageInMemory());

      expect(await log.contains('env-1'), isFalse);
    });

    test('reports an added envelope as processed', () async {
      final log = ProcessedEnvelopeLog(storage: SecureStorageInMemory());
      await log.add('env-1');

      expect(await log.contains('env-1'), isTrue);
    });

    test('carries processed envelopes across a restart', () async {
      // The redelivery that matters arrives after the app was killed between
      // decrypt and ack, so an in-memory set would never see it.
      final storage = SecureStorageInMemory();
      await ProcessedEnvelopeLog(storage: storage).add('env-1');
      await pumpEventQueue();

      final afterRestart = ProcessedEnvelopeLog(storage: storage);

      expect(await afterRestart.contains('env-1'), isTrue);
    });

    test('evicts the oldest entry once full', () async {
      final log = ProcessedEnvelopeLog(
          storage: SecureStorageInMemory(), maxEntries: 2);
      await log.add('env-1');
      await log.add('env-2');
      await log.add('env-3');

      expect(await log.contains('env-1'), isFalse);
    });

    test('keeps the newest entries once full', () async {
      final log = ProcessedEnvelopeLog(
          storage: SecureStorageInMemory(), maxEntries: 2);
      await log.add('env-1');
      await log.add('env-2');
      await log.add('env-3');

      expect(await log.contains('env-3'), isTrue);
    });

    test('ignores an empty envelope id', () async {
      final log = ProcessedEnvelopeLog(storage: SecureStorageInMemory());
      await log.add('');

      expect(await log.contains(''), isFalse);
    });
  });
}
