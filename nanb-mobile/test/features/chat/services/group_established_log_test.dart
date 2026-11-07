import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/core/secure_storage/secure_storage.dart';
import 'package:nanb_chat/features/chat/services/group_established_log.dart';

final _at = DateTime.utc(2026, 11, 6, 12);

void main() {
  group('GroupEstablishedLog', () {
    test('an unknown conversation has no time', () async {
      final log = GroupEstablishedLog(storage: SecureStorageInMemory());

      expect(await log.at('convo'), isNull);
    });

    test('returns the marked time', () async {
      final log = GroupEstablishedLog(storage: SecureStorageInMemory());

      await log.mark('convo', _at);

      expect(await log.at('convo'), _at);
    });

    test('a later mark replaces the earlier one', () async {
      final log = GroupEstablishedLog(storage: SecureStorageInMemory());
      await log.mark('convo', _at);
      final later = _at.add(const Duration(hours: 1));

      await log.mark('convo', later);

      expect(await log.at('convo'), later);
    });

    test('survives a restart', () async {
      // A catchup after a restart replays exactly the old envelopes.
      final storage = SecureStorageInMemory();
      await GroupEstablishedLog(storage: storage).mark('convo', _at);

      expect(await GroupEstablishedLog(storage: storage).at('convo'), _at);
    });

    test('evicts the oldest entry once full', () async {
      final log =
          GroupEstablishedLog(storage: SecureStorageInMemory(), maxEntries: 1);
      await log.mark('old', _at);

      await log.mark('new', _at);

      expect(await log.at('old'), isNull);
    });

    test('treats an unreadable store as empty', () async {
      final storage = SecureStorageInMemory();
      await storage.putString(GroupEstablishedLog.storageKey, 'not json');

      expect(await GroupEstablishedLog(storage: storage).at('convo'), isNull);
    });
  });
}
