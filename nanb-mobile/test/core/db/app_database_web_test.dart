import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/core/db/app_database.dart';
import 'package:nanb_chat/core/db/web/app_database_web.dart';
import 'package:nanb_chat/core/db/web/in_memory_web_db_store.dart';
import 'package:nanb_chat/core/db/web/models/web_db_snapshot.dart';
import 'package:nanb_chat/core/db/web/models/web_db_write.dart';
import 'package:nanb_chat/core/db/web/web_db_store.dart';

import 'app_database_contract.dart';
import 'contract/contract_fixtures.dart';

/// A store whose loadAll always reports unreadable data.
class _UnreadableStore extends InMemoryWebDbStore {
  int destroyCount = 0;

  @override
  Future<WebDbSnapshot> loadAll() async {
    if (destroyCount == 0) throw const WebDbUnreadableException('bad key');
    return super.loadAll();
  }

  @override
  Future<void> destroy() async {
    destroyCount++;
    await super.destroy();
  }
}

class _StoreThatRecordsBatches extends InMemoryWebDbStore {
  final batches = <List<WebDbWrite>>[];

  @override
  Future<void> applyWrites(List<WebDbWrite> writes) {
    batches.add(List.of(writes));
    return super.applyWrites(writes);
  }
}

Future<AppDatabaseWeb> _open(InMemoryWebDbStore store) async {
  final db = AppDatabaseWeb(store: store);
  await db.open(masterKeyHex: 'aa' * 32);
  return db;
}

void main() {
  group('AppDatabaseWeb contract', () {
    runAppDatabaseContract(() => AppDatabaseWeb(store: InMemoryWebDbStore()));
  });

  group('AppDatabaseWeb persistence', () {
    test('a conversation survives reopening over the same store', () async {
      final store = InMemoryWebDbStore();
      final db = await _open(store);
      await db.upsertConversation(convo('c1', unread: 4));
      await db.flush();
      final reopened = await _open(store);
      expect((await reopened.loadConversations()).single.unreadCount, 4);
    });

    test('messages survive reopening', () async {
      final store = InMemoryWebDbStore();
      final db = await _open(store);
      await seedMessages(db, 3);
      await db.flush();
      final reopened = await _open(store);
      expect(ids(await reopened.loadMessages('c1', limit: 10)),
          ['m0', 'm1', 'm2']);
    });

    test('a message survives with every field intact', () async {
      final store = InMemoryWebDbStore();
      final db = await _open(store);
      await db.upsertConversation(convo('c1'));
      final original = msg('m1', 4000, clientMsgId: 'cm')
          .copyWith(reactions: {'a': 'x'}, mediaKey: const [1, 2, 3]);
      await db.upsertMessages('c1', [original]);
      await db.flush();
      expect(await (await _open(store)).getMessage('m1'), original);
    });

    test('close flushes pending writes without an explicit flush', () async {
      final store = InMemoryWebDbStore();
      final db = await _open(store);
      await db.upsertConversation(convo('c1'));
      await db.close();
      expect(await (await _open(store)).loadConversations(), hasLength(1));
    });

    test('group members survive reopening', () async {
      final store = InMemoryWebDbStore();
      final db = await _open(store);
      await db.upsertGroupMembers('g', [member('d1'), member('d2')]);
      await db.flush();
      expect(await (await _open(store)).getGroupMembers('g'), hasLength(2));
    });

    test('ratchet state survives reopening', () async {
      final store = InMemoryWebDbStore();
      final db = await _open(store);
      await db.saveConversationCryptoState(cryptoState('c1', send: 8));
      await db.flush();
      expect(await (await _open(store)).loadConversationCryptoState('c1'),
          cryptoState('c1', send: 8));
    });

    test('tombstones survive reopening', () async {
      final store = InMemoryWebDbStore();
      final db = await _open(store);
      await db.markGroupDeleted('g');
      await db.flush();
      expect(await (await _open(store)).loadDeletedGroupIds(), {'g'});
    });

    test('a deletion is persisted', () async {
      final store = InMemoryWebDbStore();
      final db = await _open(store);
      await seedMessages(db, 2);
      await db.deleteMessage('m0');
      await db.flush();
      expect(await (await _open(store)).getMessage('m0'), isNull);
    });

    test('deleting a conversation removes its rows from the store', () async {
      final store = InMemoryWebDbStore();
      final db = await _open(store);
      await seedMessages(db, 2);
      await db.deleteConversation('c1');
      await db.flush();
      expect(store.rowCount, 0);
    });

    test('clearAll empties the store', () async {
      final store = InMemoryWebDbStore();
      final db = await _open(store);
      await seedMessages(db, 2);
      await db.markGroupDeleted('g');
      await db.flush();
      await db.clearAll();
      await db.flush();
      expect(store.rowCount, 0);
    });

    test('deleteFile empties the store', () async {
      final store = InMemoryWebDbStore();
      final db = await _open(store);
      await seedMessages(db, 2);
      await db.flush();
      await db.deleteFile();
      expect(store.rowCount, 0);
    });

    test('reopened data keeps conversation insertion order', () async {
      final store = InMemoryWebDbStore();
      final db = await _open(store);
      await db.upsertConversation(convo('b'));
      await db.upsertConversation(convo('a'));
      await db.flush();
      expect((await (await _open(store)).loadConversations()).map((c) => c.id),
          ['b', 'a']);
    });
  });

  group('AppDatabaseWeb write batching', () {
    test('a burst of upserts is one store batch', () async {
      final store = _StoreThatRecordsBatches();
      final db = await _open(store);
      for (var i = 0; i < 20; i++) {
        await db.upsertMessages('c1', [msg('m$i', 1000 + i)]);
      }
      await db.flush();
      expect(store.batches, hasLength(1));
    });

    test('repeated writes to one row are coalesced into one write', () async {
      final store = _StoreThatRecordsBatches();
      final db = await _open(store);
      for (var i = 0; i < 5; i++) {
        await db.upsertConversation(convo('c1', unread: i));
      }
      await db.flush();
      expect(store.batches.single, hasLength(1));
    });

    test('the coalesced write carries the latest value', () async {
      final store = InMemoryWebDbStore();
      final db = await _open(store);
      for (var i = 0; i < 5; i++) {
        await db.upsertConversation(convo('c1', unread: i));
      }
      await db.flush();
      expect(store.rowAt('conversations', 'c1')!['unread_count'], 4);
    });

    test('a flush with nothing pending writes nothing', () async {
      final store = _StoreThatRecordsBatches();
      final db = await _open(store);
      await db.flush();
      expect(store.batches, isEmpty);
    });

    test('a store failure surfaces from flush', () async {
      final store = InMemoryWebDbStore()..failWritesWith = StateError('disk');
      final db = await _open(store);
      await db.upsertConversation(convo('c1'));
      await expectLater(db.flush(), throwsStateError);
    });

    test('reads still work after a store failure', () async {
      final store = InMemoryWebDbStore()..failWritesWith = StateError('disk');
      final db = await _open(store);
      await db.upsertConversation(convo('c1'));
      await db.flush().catchError((Object _) {});
      expect(await db.loadConversations(), hasLength(1));
    });
  });

  group('AppDatabaseWeb transactions', () {
    test('a failed transaction leaves no partial writes in memory', () async {
      final db = await _open(InMemoryWebDbStore());
      await db.upsertConversation(convo('keep'));
      expect(
        () => db.runInTransaction(() {
          throw StateError('boom');
        }),
        throwsStateError,
      );
      expect(await db.loadConversations(), hasLength(1));
    });

    test('a transaction that throws after writing is rolled back', () async {
      final db = await _open(InMemoryWebDbStore());
      await db.upsertConversation(convo('c1', unread: 1));
      try {
        db.runInTransaction(() {
          db.upsertConversation(convo('c1', unread: 99));
          db.upsertConversation(convo('c2'));
          throw StateError('boom');
        });
      } on StateError {
        // expected
      }
      final loaded = await db.loadConversations();
      expect(loaded.map((c) => [c.id, c.unreadCount]).toList(), [
        ['c1', 1],
      ]);
    });

    test('a failed transaction restores a deleted row', () async {
      final db = await _open(InMemoryWebDbStore());
      await seedMessages(db, 2);
      try {
        db.runInTransaction(() {
          db.deleteConversation('c1');
          throw StateError('boom');
        });
      } on StateError {
        // expected
      }
      expect(ids(await db.loadMessages('c1', limit: 10)), ['m0', 'm1']);
    });

    test('a failed transaction persists nothing to the store', () async {
      final store = InMemoryWebDbStore();
      final db = await _open(store);
      try {
        db.runInTransaction(() {
          db.upsertConversation(convo('c1'));
          throw StateError('boom');
        });
      } on StateError {
        // expected
      }
      await db.flush();
      expect(store.rowCount, 0);
    });

    test('a successful transaction persists all its writes as one batch',
        () async {
      final store = _StoreThatRecordsBatches();
      final db = await _open(store);
      db.runInTransaction(() {
        db.upsertConversation(convo('c1'));
        db.upsertMessages('c1', [msg('m1', 1000)]);
      });
      await db.flush();
      expect(store.batches.single, hasLength(2));
    });
  });

  group('AppDatabaseWeb unreadable store', () {
    test('open throws DatabaseUnreadableException by default', () async {
      final db = AppDatabaseWeb(store: _UnreadableStore());
      await expectLater(db.open(masterKeyHex: 'aa'),
          throwsA(isA<DatabaseUnreadableException>()));
    });

    test('open does not destroy the store by default', () async {
      final store = _UnreadableStore();
      try {
        await AppDatabaseWeb(store: store).open(masterKeyHex: 'aa');
      } on DatabaseUnreadableException {
        // expected
      }
      expect(store.destroyCount, 0);
    });

    test('recreateIfUnreadable destroys the store and opens empty', () async {
      final store = _UnreadableStore();
      final db = AppDatabaseWeb(store: store);
      await db.open(masterKeyHex: 'aa', recreateIfUnreadable: true);
      expect([db.isOpen, store.destroyCount], [true, 1]);
    });
  });
}
