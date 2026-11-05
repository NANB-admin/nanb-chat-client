import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/core/db/app_database.dart';
import 'package:nanb_chat/features/chat/models/conversation_kind.dart';
import 'package:nanb_chat/features/chat/models/crypto_mode.dart';

import 'contract_fixtures.dart';

void runConversationContract(AppDatabase Function() create) {
  group('lifecycle', () {
    test('isOpen is false before open', () {
      expect(create().isOpen, isFalse);
    });

    test('isOpen is true after open', () async {
      expect((await openDb(create)).isOpen, isTrue);
    });

    test('isOpen is false after close', () async {
      final db = await openDb(create);
      await db.close();
      expect(db.isOpen, isFalse);
    });

    test('reads before open return empty results', () async {
      final db = create();
      expect(await db.loadConversations(), isEmpty);
    });

    test('writes before open are ignored', () async {
      final db = create();
      await db.upsertConversation(convo('c1'));
      await db.open(masterKeyHex: 'aa' * 32);
      expect(await db.loadConversations(), isEmpty);
    });
  });

  group('upsertConversation / loadConversations', () {
    test('a stored conversation loads back with its peer fields', () async {
      final db = await openDb(create);
      await db.upsertConversation(convo('c1', unread: 3));
      final loaded = (await db.loadConversations()).single;
      expect(
        [loaded.id, loaded.peerUsername, loaded.peerAccountId,
            loaded.peerDeviceId],
        ['c1', 'user-c1', 'c1-acc', 'c1-dev'],
      );
    });

    test('key material round-trips byte for byte', () async {
      final db = await openDb(create);
      await db.upsertConversation(convo('c1'));
      final loaded = (await db.loadConversations()).single;
      expect([loaded.peerIdentityPubKey, loaded.peerX25519PubKey],
          [const [1, 2, 3], const [4, 5, 6]]);
    });

    test('unread count is stored', () async {
      final db = await openDb(create);
      await db.upsertConversation(convo('c1', unread: 7));
      expect((await db.loadConversations()).single.unreadCount, 7);
    });

    test('upserting again replaces the unread count', () async {
      final db = await openDb(create);
      await db.upsertConversation(convo('c1', unread: 7));
      await db.upsertConversation(convo('c1', unread: 0));
      expect((await db.loadConversations()).single.unreadCount, 0);
    });

    test('upserting the same id does not duplicate the row', () async {
      final db = await openDb(create);
      await db.upsertConversation(convo('c1'));
      await db.upsertConversation(convo('c1'));
      expect(await db.loadConversations(), hasLength(1));
    });

    test('crypto mode round-trips', () async {
      final db = await openDb(create);
      await db.upsertConversation(convo('c1', cryptoMode: CryptoMode.mls));
      expect((await db.loadConversations()).single.cryptoMode, CryptoMode.mls);
    });

    test('conversation kind round-trips', () async {
      final db = await openDb(create);
      await db.upsertConversation(convo('g', kind: ConversationKind.group));
      expect((await db.loadConversations()).single.kind,
          ConversationKind.group);
    });

    test('pin, pinned message and pending flags round-trip', () async {
      final db = await openDb(create);
      await db.upsertConversation(
          convo('c1', pinned: true, pinnedEnvelopeId: 'e9', pending: true));
      final c = (await db.loadConversations()).single;
      expect([c.pinned, c.pinnedEnvelopeId, c.pending], [true, 'e9', true]);
    });

    test('disappearing ttl override round-trips', () async {
      final db = await openDb(create);
      await db.upsertConversation(convo('c1', disappearingTtl: 60));
      expect((await db.loadConversations()).single.disappearingTtl, 60);
    });

    test('disappearing ttl defaults to -1', () async {
      final db = await openDb(create);
      await db.upsertConversation(convo('c1'));
      expect((await db.loadConversations()).single.disappearingTtl, -1);
    });

    test('conversations come back in first-insertion order', () async {
      final db = await openDb(create);
      await db.upsertConversation(convo('b'));
      await db.upsertConversation(convo('a'));
      expect((await db.loadConversations()).map((c) => c.id), ['b', 'a']);
    });

    test('upsertConversation does not touch stored messages', () async {
      final db = await openDb(create);
      await seedMessages(db, 2);
      await db.upsertConversation(convo('c1', unread: 5));
      expect(ids(await db.loadMessages('c1', limit: 10)), ['m0', 'm1']);
    });
  });

  group('loadConversations hydration', () {
    test('hydrates only the newest N messages, oldest first', () async {
      final db = await openDb(create);
      await seedMessages(db, 5);
      final c = (await db.loadConversations(messagesPerConversation: 3))
          .single;
      expect(ids(c.messages), ['m2', 'm3', 'm4']);
    });

    test('hasMoreOlderMessages is true when older messages remain', () async {
      final db = await openDb(create);
      await seedMessages(db, 5);
      final c = (await db.loadConversations(messagesPerConversation: 3))
          .single;
      expect(c.hasMoreOlderMessages, isTrue);
    });

    test('hasMoreOlderMessages is false when the page holds everything',
        () async {
      final db = await openDb(create);
      await seedMessages(db, 3);
      final c = (await db.loadConversations(messagesPerConversation: 3))
          .single;
      expect(c.hasMoreOlderMessages, isFalse);
    });

    test('a conversation with no messages loads with an empty list', () async {
      final db = await openDb(create);
      await db.upsertConversation(convo('c1'));
      expect((await db.loadConversations()).single.messages, isEmpty);
    });

    test('messages stay in their own conversation', () async {
      final db = await openDb(create);
      await seedMessages(db, 2, convoId: 'a');
      await seedMessages(db, 3, convoId: 'b');
      final byId = {for (final c in await db.loadConversations()) c.id: c};
      expect([byId['a']!.messages.length, byId['b']!.messages.length],
          [2, 3]);
    });

    test('members are attached to their conversation', () async {
      final db = await openDb(create);
      await db.upsertConversation(convo('g', kind: ConversationKind.group));
      await db.upsertGroupMembers('g', [member('d1'), member('d2')]);
      final c = (await db.loadConversations()).single;
      expect(c.members.map((m) => m.deviceId), ['d1', 'd2']);
    });

    test('a conversation without members loads an empty member list',
        () async {
      final db = await openDb(create);
      await db.upsertConversation(convo('c1'));
      expect((await db.loadConversations()).single.members, isEmpty);
    });
  });

  group('upsertConversationWithMessages', () {
    test('stores the conversation row', () async {
      final db = await openDb(create);
      await db.upsertConversationWithMessages(
          convo('c1', unread: 2), [msg('m1', 1000)]);
      expect((await db.loadConversations()).single.unreadCount, 2);
    });

    test('stores the messages', () async {
      final db = await openDb(create);
      await db.upsertConversationWithMessages(
          convo('c1'), [msg('m1', 1000), msg('m2', 2000)]);
      expect(ids(await db.loadMessages('c1', limit: 10)), ['m1', 'm2']);
    });

    test('works with an empty message list', () async {
      final db = await openDb(create);
      await db.upsertConversationWithMessages(convo('c1'), const []);
      expect(await db.loadConversations(), hasLength(1));
    });

    test('an existing message with the same envelope id is overwritten',
        () async {
      final db = await openDb(create);
      await db.upsertConversationWithMessages(
          convo('c1'), [msg('m1', 1000, body: 'old')]);
      await db.upsertConversationWithMessages(
          convo('c1'), [msg('m1', 1000, body: 'new')]);
      expect((await db.getMessage('m1'))!.body, 'new');
    });
  });

  group('deleteConversation / clearMessagesForConversation', () {
    test('deleteConversation removes the conversation row', () async {
      final db = await openDb(create);
      await seedMessages(db, 1);
      await db.deleteConversation('c1');
      expect(await db.loadConversations(), isEmpty);
    });

    test('deleteConversation cascades to its messages', () async {
      final db = await openDb(create);
      await seedMessages(db, 2);
      await db.deleteConversation('c1');
      expect(await db.loadMessages('c1', limit: 10), isEmpty);
    });

    test('deleteConversation cascades to its group members', () async {
      final db = await openDb(create);
      await db.upsertConversation(convo('g'));
      await db.upsertGroupMembers('g', [member('d1')]);
      await db.deleteConversation('g');
      expect(await db.getGroupMembers('g'), isEmpty);
    });

    test('deleteConversation leaves other conversations alone', () async {
      final db = await openDb(create);
      await seedMessages(db, 1, convoId: 'a');
      await seedMessages(db, 1, convoId: 'b');
      await db.deleteConversation('a');
      expect(ids(await db.loadMessages('b', limit: 10)), ['b:m0']);
    });

    test('deleteConversation does not remove ratchet state', () async {
      final db = await openDb(create);
      await db.upsertConversation(convo('c1'));
      await db.saveConversationCryptoState(cryptoState('c1'));
      await db.deleteConversation('c1');
      expect(await db.loadConversationCryptoState('c1'), isNotNull);
    });

    test('deleteConversation of an unknown id is a no-op', () async {
      final db = await openDb(create);
      await db.upsertConversation(convo('c1'));
      await db.deleteConversation('nope');
      expect(await db.loadConversations(), hasLength(1));
    });

    test('clearMessagesForConversation removes its messages', () async {
      final db = await openDb(create);
      await seedMessages(db, 2);
      await db.clearMessagesForConversation('c1');
      expect(await db.loadMessages('c1', limit: 10), isEmpty);
    });

    test('clearMessagesForConversation keeps the conversation row', () async {
      final db = await openDb(create);
      await seedMessages(db, 2);
      await db.clearMessagesForConversation('c1');
      expect(await db.loadConversations(), hasLength(1));
    });

    test('clearMessagesForConversation keeps group members', () async {
      final db = await openDb(create);
      await db.upsertConversation(convo('g'));
      await db.upsertGroupMembers('g', [member('d1')]);
      await db.clearMessagesForConversation('g');
      expect(await db.getGroupMembers('g'), hasLength(1));
    });

    test('clearMessagesForConversation leaves other conversations alone',
        () async {
      final db = await openDb(create);
      await seedMessages(db, 1, convoId: 'a');
      await seedMessages(db, 1, convoId: 'b');
      await db.clearMessagesForConversation('a');
      expect(ids(await db.loadMessages('b', limit: 10)), ['b:m0']);
    });
  });

  group('clearAll / deleteFile', () {
    test('clearAll removes conversations', () async {
      final db = await openDb(create);
      await seedMessages(db, 1);
      await db.clearAll();
      expect(await db.loadConversations(), isEmpty);
    });

    test('clearAll removes messages', () async {
      final db = await openDb(create);
      await seedMessages(db, 1);
      await db.clearAll();
      expect(await db.getMessage('m0'), isNull);
    });

    test('clearAll removes ratchet state', () async {
      final db = await openDb(create);
      await db.saveConversationCryptoState(cryptoState('c1'));
      await db.clearAll();
      expect(await db.loadConversationCryptoState('c1'), isNull);
    });

    test('clearAll removes group members', () async {
      final db = await openDb(create);
      await db.upsertGroupMembers('g', [member('d1')]);
      await db.clearAll();
      expect(await db.getGroupMembers('g'), isEmpty);
    });

    test('clearAll removes group tombstones', () async {
      final db = await openDb(create);
      await db.markGroupDeleted('g');
      await db.clearAll();
      expect(await db.loadDeletedGroupIds(), isEmpty);
    });

    test('the database is still usable after clearAll', () async {
      final db = await openDb(create);
      await db.clearAll();
      await db.upsertConversation(convo('c1'));
      expect(await db.loadConversations(), hasLength(1));
    });

    test('deleteFile closes the database', () async {
      final db = await openDb(create);
      await db.deleteFile();
      expect(db.isOpen, isFalse);
    });

    test('a fresh open after deleteFile is empty', () async {
      final db = await openDb(create);
      await seedMessages(db, 2);
      await db.deleteFile();
      await db.open(masterKeyHex: 'bb' * 32);
      expect(await db.loadConversations(), isEmpty);
    });
  });
}
