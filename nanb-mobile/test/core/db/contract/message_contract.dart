import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/core/db/app_database.dart';
import 'package:nanb_chat/features/chat/models/chat_message.dart';
import 'package:nanb_chat/features/chat/models/message_kind.dart';

import 'contract_fixtures.dart';

void runMessageContract(AppDatabase Function() create) {
  group('loadMessages', () {
    test('returns messages ascending by server timestamp', () async {
      final db = await openDb(create);
      await db.upsertConversation(convo('c1'));
      await db.upsertMessages(
          'c1', [msg('late', 3000), msg('early', 1000), msg('mid', 2000)]);
      expect(ids(await db.loadMessages('c1', limit: 10)),
          ['early', 'mid', 'late']);
    });

    test('limit keeps the newest messages', () async {
      final db = await openDb(create);
      await seedMessages(db, 5);
      expect(ids(await db.loadMessages('c1', limit: 2)), ['m3', 'm4']);
    });

    test('limit larger than the count returns everything', () async {
      final db = await openDb(create);
      await seedMessages(db, 3);
      expect(await db.loadMessages('c1', limit: 100), hasLength(3));
    });

    test('a zero limit returns nothing', () async {
      final db = await openDb(create);
      await seedMessages(db, 3);
      expect(await db.loadMessages('c1', limit: 0), isEmpty);
    });

    test('beforeServerTsMs returns only strictly older messages', () async {
      final db = await openDb(create);
      await seedMessages(db, 5); // ts 1000..5000
      expect(
          ids(await db.loadMessages('c1', limit: 10, beforeServerTsMs: 3000)),
          ['m0', 'm1']);
    });

    test('beforeServerTsMs combined with limit keeps the newest of the older',
        () async {
      final db = await openDb(create);
      await seedMessages(db, 5);
      expect(
          ids(await db.loadMessages('c1', limit: 1, beforeServerTsMs: 4000)),
          ['m2']);
    });

    test('a cursor older than every message returns nothing', () async {
      final db = await openDb(create);
      await seedMessages(db, 3);
      expect(
          await db.loadMessages('c1', limit: 10, beforeServerTsMs: 1000),
          isEmpty);
    });

    test('an unknown conversation returns nothing', () async {
      final db = await openDb(create);
      expect(await db.loadMessages('nope', limit: 10), isEmpty);
    });

    test('only the requested conversation is returned', () async {
      final db = await openDb(create);
      await seedMessages(db, 2, convoId: 'a');
      await seedMessages(db, 1, convoId: 'b');
      expect(ids(await db.loadMessages('b', limit: 10)), ['b:m0']);
    });

    test('timestamp ties keep insertion order', () async {
      final db = await openDb(create);
      await db.upsertConversation(convo('c1'));
      await db.upsertMessages(
          'c1', [msg('first', 1000), msg('second', 1000)]);
      expect(ids(await db.loadMessages('c1', limit: 10)), ['first', 'second']);
    });
  });

  group('upsertMessages', () {
    test('an existing envelope id is overwritten', () async {
      final db = await openDb(create);
      await db.upsertConversation(convo('c1'));
      await db.upsertMessages('c1', [msg('m1', 1000, body: 'old')]);
      await db.upsertMessages('c1', [msg('m1', 1000, body: 'new')]);
      expect((await db.loadMessages('c1', limit: 10)).single.body, 'new');
    });

    test('overwriting does not duplicate the message', () async {
      final db = await openDb(create);
      await db.upsertConversation(convo('c1'));
      await db.upsertMessages('c1', [msg('m1', 1000)]);
      await db.upsertMessages('c1', [msg('m1', 1000)]);
      expect(await db.loadMessages('c1', limit: 10), hasLength(1));
    });

    test('an overwrite can move the message in time', () async {
      final db = await openDb(create);
      await db.upsertConversation(convo('c1'));
      await db.upsertMessages('c1', [msg('a', 1000), msg('b', 2000)]);
      await db.upsertMessages('c1', [msg('a', 3000)]);
      expect(ids(await db.loadMessages('c1', limit: 10)), ['b', 'a']);
    });

    test('an empty list is a no-op', () async {
      final db = await openDb(create);
      await db.upsertMessages('c1', const []);
      expect(await db.loadMessages('c1', limit: 10), isEmpty);
    });

    test('messages can be stored without a conversation row', () async {
      final db = await openDb(create);
      await db.upsertMessages('orphan', [msg('m1', 1000, convoId: 'orphan')]);
      expect(await db.getMessage('m1'), isNotNull);
    });
  });

  group('message field round trip', () {
    test('all optional media fields round-trip', () async {
      final db = await openDb(create);
      await db.upsertConversation(convo('c1'));
      final original = ChatMessage(
        envelopeId: 'm1',
        conversationId: 'c1',
        senderDeviceId: 'dev-a',
        body: 'caption',
        serverTs: DateTime.fromMillisecondsSinceEpoch(5000, isUtc: true),
        mine: true,
        outboxId: 'ob1',
        clientMsgId: 'cm1',
        kind: MessageKind.voice,
        mediaId: 'media1',
        mediaKey: const [1, 2],
        mediaSha256: const [3, 4],
        mediaSize: 99,
        mediaMime: 'audio/ogg',
        mediaFilename: 'a.ogg',
        voiceWaveform: const [5, 6],
        mediaDurationMs: 1234,
        pendingUploadKey: const [7, 8],
        uploading: true,
        failed: true,
      );
      await db.upsertMessages('c1', [original]);
      expect(await db.getMessage('m1'), original);
    });

    test('reply, forwarded and edited fields round-trip', () async {
      final db = await openDb(create);
      await db.upsertConversation(convo('c1'));
      final original = ChatMessage(
        envelopeId: 'm1',
        conversationId: 'c1',
        senderDeviceId: 'dev-a',
        body: 'b',
        serverTs: DateTime.fromMillisecondsSinceEpoch(5000, isUtc: true),
        mine: false,
        replyToEnvelopeId: 'q1',
        replyToSender: 'bob',
        replyToPreview: 'quoted',
        forwarded: true,
        edited: true,
      );
      await db.upsertMessages('c1', [original]);
      expect(await db.getMessage('m1'), original);
    });

    test('reactions round-trip', () async {
      final db = await openDb(create);
      await db.upsertConversation(convo('c1'));
      final original = msg('m1', 1000).copyWith(reactions: {'acc1': '👍'});
      await db.upsertMessages('c1', [original]);
      expect((await db.getMessage('m1'))!.reactions, {'acc1': '👍'});
    });

    test('delivery status and receipt times round-trip', () async {
      final db = await openDb(create);
      await db.upsertConversation(convo('c1'));
      final at = DateTime.fromMillisecondsSinceEpoch(9000, isUtc: true);
      final original = msg('m1', 1000).copyWith(
        deliveryStatus: MessageDeliveryStatus.read,
        deliveredAt: at,
        readAt: at,
      );
      await db.upsertMessages('c1', [original]);
      final loaded = (await db.getMessage('m1'))!;
      expect([loaded.deliveryStatus, loaded.deliveredAt, loaded.readAt],
          [MessageDeliveryStatus.read, at, at]);
    });

    test('expiresAt round-trips as the same instant', () async {
      final db = await openDb(create);
      await db.upsertConversation(convo('c1'));
      final at = DateTime.fromMillisecondsSinceEpoch(8000, isUtc: true);
      await db.upsertMessages('c1', [msg('m1', 1000, expiresAt: at)]);
      expect((await db.getMessage('m1'))!.expiresAt, at);
    });

    test('a message with no optional fields has them all null', () async {
      final db = await openDb(create);
      await db.upsertConversation(convo('c1'));
      await db.upsertMessages('c1', [msg('m1', 1000)]);
      final m = (await db.getMessage('m1'))!;
      expect([m.mediaId, m.outboxId, m.clientMsgId, m.expiresAt, m.linkPreview],
          [null, null, null, null, null]);
    });
  });

  group('getMessage / deleteMessage', () {
    test('getMessage finds a message by envelope id', () async {
      final db = await openDb(create);
      await seedMessages(db, 3);
      expect((await db.getMessage('m1'))!.envelopeId, 'm1');
    });

    test('getMessage searches across conversations', () async {
      final db = await openDb(create);
      await seedMessages(db, 1, convoId: 'a');
      await db.upsertMessages('b', [msg('only-b', 1000, convoId: 'b')]);
      expect((await db.getMessage('only-b'))!.conversationId, 'b');
    });

    test('getMessage returns null for an unknown id', () async {
      final db = await openDb(create);
      expect(await db.getMessage('nope'), isNull);
    });

    test('deleteMessage removes just that message', () async {
      final db = await openDb(create);
      await seedMessages(db, 3);
      await db.deleteMessage('m1');
      expect(ids(await db.loadMessages('c1', limit: 10)), ['m0', 'm2']);
    });

    test('deleteMessage of an unknown id is a no-op', () async {
      final db = await openDb(create);
      await seedMessages(db, 2);
      await db.deleteMessage('nope');
      expect(await db.loadMessages('c1', limit: 10), hasLength(2));
    });
  });

  group('hasMessageWithClientId', () {
    test('is true for a matching sender and client id', () async {
      final db = await openDb(create);
      await db.upsertConversation(convo('c1'));
      await db.upsertMessages(
          'c1', [msg('m1', 1000, sender: 'dev-a', clientMsgId: 'cm1')]);
      expect(await db.hasMessageWithClientId('c1', 'dev-a', 'cm1'), isTrue);
    });

    test('is false for a different sender device', () async {
      final db = await openDb(create);
      await db.upsertConversation(convo('c1'));
      await db.upsertMessages(
          'c1', [msg('m1', 1000, sender: 'dev-a', clientMsgId: 'cm1')]);
      expect(await db.hasMessageWithClientId('c1', 'dev-b', 'cm1'), isFalse);
    });

    test('is false for a different client id', () async {
      final db = await openDb(create);
      await db.upsertConversation(convo('c1'));
      await db.upsertMessages(
          'c1', [msg('m1', 1000, sender: 'dev-a', clientMsgId: 'cm1')]);
      expect(await db.hasMessageWithClientId('c1', 'dev-a', 'cm2'), isFalse);
    });

    test('is false for a different conversation', () async {
      final db = await openDb(create);
      await db.upsertConversation(convo('c1'));
      await db.upsertMessages(
          'c1', [msg('m1', 1000, sender: 'dev-a', clientMsgId: 'cm1')]);
      expect(await db.hasMessageWithClientId('c2', 'dev-a', 'cm1'), isFalse);
    });

    test('is false once the message is deleted', () async {
      final db = await openDb(create);
      await db.upsertConversation(convo('c1'));
      await db.upsertMessages(
          'c1', [msg('m1', 1000, sender: 'dev-a', clientMsgId: 'cm1')]);
      await db.deleteMessage('m1');
      expect(await db.hasMessageWithClientId('c1', 'dev-a', 'cm1'), isFalse);
    });
  });

  group('trimMessages', () {
    test('keeps the newest N messages', () async {
      final db = await openDb(create);
      await seedMessages(db, 5);
      await db.trimMessages('c1', keep: 2);
      expect(ids(await db.loadMessages('c1', limit: 10)), ['m3', 'm4']);
    });

    test('is a no-op when there are fewer than N', () async {
      final db = await openDb(create);
      await seedMessages(db, 2);
      await db.trimMessages('c1', keep: 5);
      expect(await db.loadMessages('c1', limit: 10), hasLength(2));
    });

    test('keep 0 removes every message', () async {
      final db = await openDb(create);
      await seedMessages(db, 3);
      await db.trimMessages('c1', keep: 0);
      expect(await db.loadMessages('c1', limit: 10), isEmpty);
    });

    test('does not touch other conversations', () async {
      final db = await openDb(create);
      await seedMessages(db, 3, convoId: 'a');
      await seedMessages(db, 3, convoId: 'b');
      await db.trimMessages('a', keep: 1);
      expect(await db.loadMessages('b', limit: 10), hasLength(3));
    });

    test('keeps the conversation row', () async {
      final db = await openDb(create);
      await seedMessages(db, 3);
      await db.trimMessages('c1', keep: 1);
      expect(await db.loadConversations(), hasLength(1));
    });
  });

  group('searchMessages', () {
    test('matches a case-insensitive substring', () async {
      final db = await openDb(create);
      await db.upsertConversation(convo('c1'));
      await db.upsertMessages('c1', [
        msg('m1', 1000, body: 'Hello World'),
        msg('m2', 2000, body: 'nothing'),
      ]);
      expect(ids(await db.searchMessages('c1', 'WORLD')), ['m1']);
    });

    test('results are newest first', () async {
      final db = await openDb(create);
      await db.upsertConversation(convo('c1'));
      await db.upsertMessages('c1', [
        msg('b', 2000, body: 'cat'),
        msg('a', 1000, body: 'cat'),
      ]);
      expect(ids(await db.searchMessages('c1', 'cat')), ['b', 'a']);
    });

    test('the limit keeps the newest matches', () async {
      final db = await openDb(create);
      await db.upsertConversation(convo('c1'));
      await db.upsertMessages('c1', [
        msg('old', 1000, body: 'cat'),
        msg('mid', 2000, body: 'cat'),
        msg('new', 3000, body: 'cat'),
      ]);
      expect(ids(await db.searchMessages('c1', 'cat', limit: 2)), ['new', 'mid']);
    });

    test('an empty query returns nothing', () async {
      final db = await openDb(create);
      await seedMessages(db, 2);
      expect(await db.searchMessages('c1', ''), isEmpty);
    });

    test('a whitespace-only query returns nothing', () async {
      final db = await openDb(create);
      await seedMessages(db, 2);
      expect(await db.searchMessages('c1', '   '), isEmpty);
    });

    test('the query is trimmed before matching', () async {
      final db = await openDb(create);
      await db.upsertConversation(convo('c1'));
      await db.upsertMessages('c1', [msg('m1', 1000, body: 'foo')]);
      expect(ids(await db.searchMessages('c1', '  foo ')), ['m1']);
    });

    test('non-text messages are excluded', () async {
      final db = await openDb(create);
      await db.upsertConversation(convo('c1'));
      await db.upsertMessages('c1', [
        msg('img', 1000, body: 'sunset', kind: MessageKind.image),
        msg('txt', 2000, body: 'sunset'),
      ]);
      expect(ids(await db.searchMessages('c1', 'sunset')), ['txt']);
    });

    test('only the given conversation is searched', () async {
      final db = await openDb(create);
      await db.upsertMessages('a', [msg('ma', 1000, convoId: 'a', body: 'x')]);
      await db.upsertMessages('b', [msg('mb', 1000, convoId: 'b', body: 'x')]);
      expect(ids(await db.searchMessages('a', 'x')), ['ma']);
    });

    test('a percent sign in the query is literal', () async {
      final db = await openDb(create);
      await db.upsertConversation(convo('c1'));
      await db.upsertMessages('c1', [
        msg('m1', 1000, body: '100% sure'),
        msg('m2', 2000, body: 'plain'),
      ]);
      expect(ids(await db.searchMessages('c1', '%')), ['m1']);
    });

    test('an underscore in the query is literal', () async {
      final db = await openDb(create);
      await db.upsertConversation(convo('c1'));
      await db.upsertMessages('c1', [
        msg('m1', 1000, body: 'snake_case'),
        msg('m2', 2000, body: 'snakecase'),
      ]);
      expect(ids(await db.searchMessages('c1', 'e_c')), ['m1']);
    });
  });
}
