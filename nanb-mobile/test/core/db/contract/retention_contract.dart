import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/core/db/app_database.dart';

import 'contract_fixtures.dart';

DateTime _at(int ms) => DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);

void runRetentionContract(AppDatabase Function() create) {
  group('deleteExpiredMessages', () {
    test('removes a message whose expiry is in the past', () async {
      final db = await openDb(create);
      await db.upsertConversation(convo('c1'));
      await db.upsertMessages('c1', [msg('m1', 1000, expiresAt: _at(5000))]);
      await db.deleteExpiredMessages(_at(6000));
      expect(await db.getMessage('m1'), isNull);
    });

    test('removes a message expiring exactly now', () async {
      final db = await openDb(create);
      await db.upsertConversation(convo('c1'));
      await db.upsertMessages('c1', [msg('m1', 1000, expiresAt: _at(5000))]);
      await db.deleteExpiredMessages(_at(5000));
      expect(await db.getMessage('m1'), isNull);
    });

    test('keeps a message expiring in the future', () async {
      final db = await openDb(create);
      await db.upsertConversation(convo('c1'));
      await db.upsertMessages('c1', [msg('m1', 1000, expiresAt: _at(5000))]);
      await db.deleteExpiredMessages(_at(4999));
      expect(await db.getMessage('m1'), isNotNull);
    });

    test('keeps messages with no expiry', () async {
      final db = await openDb(create);
      await db.upsertConversation(convo('c1'));
      await db.upsertMessages('c1', [msg('m1', 1000)]);
      await db.deleteExpiredMessages(_at(999999999));
      expect(await db.getMessage('m1'), isNotNull);
    });

    test('returns the number of rows removed', () async {
      final db = await openDb(create);
      await db.upsertConversation(convo('c1'));
      await db.upsertMessages('c1', [
        msg('m1', 1000, expiresAt: _at(2000)),
        msg('m2', 1000, expiresAt: _at(3000)),
        msg('m3', 1000, expiresAt: _at(9000)),
      ]);
      expect(await db.deleteExpiredMessages(_at(4000)), 2);
    });

    test('returns 0 when nothing expires', () async {
      final db = await openDb(create);
      await seedMessages(db, 2);
      expect(await db.deleteExpiredMessages(_at(999999999)), 0);
    });

    test('sweeps every conversation', () async {
      final db = await openDb(create);
      await db.upsertMessages(
          'a', [msg('ma', 1000, convoId: 'a', expiresAt: _at(2000))]);
      await db.upsertMessages(
          'b', [msg('mb', 1000, convoId: 'b', expiresAt: _at(2000))]);
      expect(await db.deleteExpiredMessages(_at(3000)), 2);
    });
  });

  group('deleteMessagesPastLocalRetention', () {
    test('global ttl removes messages older than it', () async {
      final db = await openDb(create);
      await db.upsertConversation(convo('c1'));
      await db.upsertMessages('c1', [msg('old', 1000), msg('new', 9000)]);
      await db.deleteMessagesPastLocalRetention(_at(10000), 5);
      expect(ids(await db.loadMessages('c1', limit: 10)), ['new']);
    });

    test('a message exactly at its ttl boundary is removed', () async {
      final db = await openDb(create);
      await db.upsertConversation(convo('c1'));
      await db.upsertMessages('c1', [msg('m1', 1000)]);
      await db.deleteMessagesPastLocalRetention(_at(6000), 5);
      expect(await db.getMessage('m1'), isNull);
    });

    test('a message one millisecond inside its ttl is kept', () async {
      final db = await openDb(create);
      await db.upsertConversation(convo('c1'));
      await db.upsertMessages('c1', [msg('m1', 1000)]);
      await db.deleteMessagesPastLocalRetention(_at(5999), 5);
      expect(await db.getMessage('m1'), isNotNull);
    });

    test('returns the number of rows removed', () async {
      final db = await openDb(create);
      await db.upsertConversation(convo('c1'));
      await db.upsertMessages(
          'c1', [msg('a', 1000), msg('b', 2000), msg('c', 99000)]);
      expect(await db.deleteMessagesPastLocalRetention(_at(100000), 10), 2);
    });

    test('null global ttl and no overrides removes nothing', () async {
      final db = await openDb(create);
      await seedMessages(db, 3);
      expect(await db.deleteMessagesPastLocalRetention(_at(99999999), null),
          0);
    });

    test('null global ttl leaves messages in a conversation with no override',
        () async {
      final db = await openDb(create);
      await seedMessages(db, 1);
      await db.deleteMessagesPastLocalRetention(_at(99999999), null);
      expect(await db.getMessage('m0'), isNotNull);
    });

    test('a per-conversation override applies even with a null global ttl',
        () async {
      final db = await openDb(create);
      await db.upsertConversation(convo('c1', disappearingTtl: 5));
      await db.upsertMessages('c1', [msg('m1', 1000)]);
      await db.deleteMessagesPastLocalRetention(_at(10000), null);
      expect(await db.getMessage('m1'), isNull);
    });

    test('the override wins over a longer global ttl', () async {
      final db = await openDb(create);
      await db.upsertConversation(convo('c1', disappearingTtl: 5));
      await db.upsertMessages('c1', [msg('m1', 1000)]);
      await db.deleteMessagesPastLocalRetention(_at(10000), 3600);
      expect(await db.getMessage('m1'), isNull);
    });

    test('the override wins over a shorter global ttl', () async {
      final db = await openDb(create);
      await db.upsertConversation(convo('c1', disappearingTtl: 3600));
      await db.upsertMessages('c1', [msg('m1', 1000)]);
      await db.deleteMessagesPastLocalRetention(_at(10000), 5);
      expect(await db.getMessage('m1'), isNotNull);
    });

    test('a conversation without override uses the global ttl while another '
        'uses its own', () async {
      final db = await openDb(create);
      await db.upsertConversation(convo('a', disappearingTtl: 3600));
      await db.upsertConversation(convo('b'));
      await db.upsertMessages('a', [msg('ma', 1000, convoId: 'a')]);
      await db.upsertMessages('b', [msg('mb', 1000, convoId: 'b')]);
      await db.deleteMessagesPastLocalRetention(_at(10000), 5);
      expect([await db.getMessage('ma'), await db.getMessage('mb')],
          [isNotNull, isNull]);
    });

    test('ignores the per-message expiresAt', () async {
      final db = await openDb(create);
      await db.upsertConversation(convo('c1'));
      await db.upsertMessages('c1', [msg('m1', 1000, expiresAt: _at(1))]);
      await db.deleteMessagesPastLocalRetention(_at(10000), null);
      expect(await db.getMessage('m1'), isNotNull);
    });
  });
}
