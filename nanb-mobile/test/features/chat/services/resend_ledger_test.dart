import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/core/secure_storage/secure_storage.dart';
import 'package:nanb_chat/features/chat/services/resend_ledger.dart';

final _at = DateTime.utc(2026, 11, 6, 12);

void main() {
  group('ResendLedger', () {
    test('a message never re-sent has no attempts', () async {
      final ledger = ResendLedger(storage: SecureStorageInMemory());

      expect((await ledger.attempt('cid')).count, 0);
    });

    test('counts each recorded attempt', () async {
      final ledger = ResendLedger(storage: SecureStorageInMemory());

      await ledger.recordAttempts(['cid'], _at);
      await ledger.recordAttempts(['cid'], _at);

      expect((await ledger.attempt('cid')).count, 2);
    });

    test('remembers when it was last re-sent', () async {
      final ledger = ResendLedger(storage: SecureStorageInMemory());

      await ledger.recordAttempts(['cid'], _at);

      expect((await ledger.attempt('cid')).lastAtMs, _at.millisecondsSinceEpoch);
    });

    test('attempts survive a restart', () async {
      // Otherwise every launch would start the budget over and re-send forever.
      final storage = SecureStorageInMemory();
      await ResendLedger(storage: storage).recordAttempts(['cid'], _at);

      expect((await ResendLedger(storage: storage).attempt('cid')).count, 1);
    });

    test('evicts the oldest attempt once full', () async {
      final ledger =
          ResendLedger(storage: SecureStorageInMemory(), maxAttempts: 1);
      await ledger.recordAttempts(['old'], _at);

      await ledger.recordAttempts(['new'], _at);

      expect((await ledger.attempt('old')).count, 0);
    });

    test('an owed resend survives a restart', () async {
      // The app can be killed before the timer fires, and that group change
      // never happens again.
      final storage = SecureStorageInMemory();
      await ResendLedger(storage: storage).markPending('convo');

      expect(await ResendLedger(storage: storage).pendingConversations(),
          {'convo'});
    });

    test('clearing an owed resend removes it', () async {
      final storage = SecureStorageInMemory();
      final ledger = ResendLedger(storage: storage);
      await ledger.markPending('convo');

      await ledger.clearPending('convo');

      expect(await ResendLedger(storage: storage).pendingConversations(),
          isEmpty);
    });

    test('starts over when the stored data is unreadable', () async {
      final storage = SecureStorageInMemory();
      await storage.putString(ResendLedger.storageKey, 'not json');

      expect((await ResendLedger(storage: storage).attempt('cid')).count, 0);
    });
  });
}
