import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/core/secure_storage/secure_storage.dart';
import 'package:nanb_chat/features/chat/services/transport_receipt_log.dart';

void main() {
  group('TransportReceiptLog', () {
    test('remembers a message confirmed only by the transport', () async {
      final log = TransportReceiptLog(storage: SecureStorageInMemory());

      await log.add('env-1');

      expect(await log.contains('env-1'), isTrue);
    });

    test('does not report an unknown message', () async {
      final log = TransportReceiptLog(storage: SecureStorageInMemory());

      expect(await log.contains('env-1'), isFalse);
    });

    test('forgets a message once it is confirmed end to end', () async {
      final log = TransportReceiptLog(storage: SecureStorageInMemory());
      await log.add('env-1');

      await log.remove('env-1');

      expect(await log.contains('env-1'), isFalse);
    });

    test('survives a restart', () async {
      final storage = SecureStorageInMemory();
      await TransportReceiptLog(storage: storage).add('env-1');

      expect(await TransportReceiptLog(storage: storage).contains('env-1'),
          isTrue);
    });

    test('evicts the oldest entry once full', () async {
      final log = TransportReceiptLog(
          storage: SecureStorageInMemory(), maxEntries: 1);
      await log.add('old');

      await log.add('new');

      expect(await log.contains('old'), isFalse);
    });

    test('treats an unreadable store as empty', () async {
      final storage = SecureStorageInMemory();
      await storage.putString(TransportReceiptLog.storageKey, 'not json');

      expect(await TransportReceiptLog(storage: storage).contains('env-1'),
          isFalse);
    });
  });
}
