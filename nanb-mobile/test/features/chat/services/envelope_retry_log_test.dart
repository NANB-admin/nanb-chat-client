import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/core/secure_storage/secure_storage.dart';
import 'package:nanb_chat/features/chat/services/envelope_retry_log.dart';

void main() {
  group('EnvelopeRetryLog', () {
    test('counts consecutive failures for an envelope', () async {
      final log = EnvelopeRetryLog(storage: SecureStorageInMemory());

      expect(await log.recordFailure('env-1'), 1);
      expect(await log.recordFailure('env-1'), 2);
    });

    test('counts an envelope once per delivery pass', () async {
      // The receiver and the catchup backstop both report the same undecryptable
      // envelope. Counting both burned the budget twice as fast, so a message
      // was destroyed on the third reconnect instead of the fifth.
      final log = EnvelopeRetryLog(storage: SecureStorageInMemory());
      log.beginPass();
      await log.recordFailure('env-1');

      expect(await log.recordFailure('env-1'), 1);
    });

    test('counts an envelope again in the next delivery pass', () async {
      final log = EnvelopeRetryLog(storage: SecureStorageInMemory());
      log.beginPass();
      await log.recordFailure('env-1');
      log.beginPass();

      expect(await log.recordFailure('env-1'), 2);
    });

    test('carries the count across a restart', () async {
      // THE bug this exists for: the count used to live in an in-memory map, so
      // it reset on every app start — and a poison envelope fails exactly once
      // per launch, which made the drop threshold unreachable and left the
      // envelope re-draining forever.
      final storage = SecureStorageInMemory();
      await EnvelopeRetryLog(storage: storage).recordFailure('env-1');

      final afterRestart = EnvelopeRetryLog(storage: storage);

      expect(await afterRestart.recordFailure('env-1'), 2);
    });

    test('counts each envelope separately', () async {
      final log = EnvelopeRetryLog(storage: SecureStorageInMemory());

      await log.recordFailure('env-1');

      expect(await log.recordFailure('env-2'), 1);
    });

    test('forget clears the count so a later failure starts over', () async {
      // Called on success and after an ack+drop, so a recycled envelope id
      // can't inherit a stale count and be dropped immediately.
      final log = EnvelopeRetryLog(storage: SecureStorageInMemory());
      await log.recordFailure('env-1');
      await log.recordFailure('env-1');

      await log.forget('env-1');

      expect(await log.recordFailure('env-1'), 1);
    });

    test('forget survives a restart too', () async {
      final storage = SecureStorageInMemory();
      final log = EnvelopeRetryLog(storage: storage);
      await log.recordFailure('env-1');
      await log.forget('env-1');

      expect(await EnvelopeRetryLog(storage: storage).recordFailure('env-1'), 1);
    });

    test('evicts the oldest entry once full', () async {
      final storage = SecureStorageInMemory();
      final log = EnvelopeRetryLog(storage: storage, maxEntries: 2);

      await log.recordFailure('old');
      await log.recordFailure('mid');
      await log.recordFailure('new');

      // 'old' was evicted, so it starts counting from scratch.
      expect(await log.recordFailure('old'), 1);
    });

    test('reports how many failures it recorded this session', () async {
      // Lets the catchup drain surface failures the receivers swallowed, which
      // it otherwise counts as successes.
      final log = EnvelopeRetryLog(storage: SecureStorageInMemory());

      await log.recordFailure('env-1');
      await log.recordFailure('env-2');

      expect(log.failuresRecorded, 2);
    });

    test('ignores an empty envelope id', () async {
      final log = EnvelopeRetryLog(storage: SecureStorageInMemory());

      expect(await log.recordFailure(''), 0);
      expect(log.failuresRecorded, 0);
    });

    test('starts over when the stored map is unreadable', () async {
      // Degrades to one more redelivery round, never a lost message.
      final storage = SecureStorageInMemory();
      await storage.putString(EnvelopeRetryLog.storageKey, 'not json');

      expect(await EnvelopeRetryLog(storage: storage).recordFailure('env-1'), 1);
    });
  });
}
