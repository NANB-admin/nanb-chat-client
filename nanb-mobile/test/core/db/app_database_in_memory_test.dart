import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/core/crypto/conversation_crypto_state.dart';
import 'package:nanb_chat/core/db/app_database.dart';
import 'package:nanb_chat/features/chat/models/chat_message.dart';
import 'package:nanb_chat/features/chat/models/conversation.dart';
import 'package:nanb_chat/features/chat/models/message_kind.dart';

Conversation _convo({
  String id = 'c1',
  String username = 'alice',
  int unread = 0,
  List<ChatMessage> messages = const [],
}) {
  return Conversation(
    id: id,
    peerUsername: username,
    peerAccountId: '$id-acc',
    peerDeviceId: '$id-dev',
    peerIdentityPubKey: const [1, 2, 3],
    messages: messages,
    unreadCount: unread,
  );
}

ChatMessage _msg(String id, DateTime ts, {String convoId = 'c1', String body = 'hi'}) {
  return ChatMessage(
    envelopeId: id,
    conversationId: convoId,
    senderDeviceId: 'd',
    body: body,
    serverTs: ts,
    mine: false,
  );
}

void main() {
  group('AppDatabaseInMemory lifecycle', () {
    test('isOpen toggles via open/close', () async {
      final db = AppDatabaseInMemory();
      expect(db.isOpen, isFalse);
      await db.open(masterKeyHex: 'k');
      expect(db.isOpen, isTrue);
      await db.close();
      expect(db.isOpen, isFalse);
    });
  });

  group('AppDatabaseInMemory conversations', () {
    late AppDatabaseInMemory db;
    setUp(() async {
      db = AppDatabaseInMemory();
      await db.open(masterKeyHex: 'k');
    });

    test('upsertConversation adds a row', () async {
      await db.upsertConversation(_convo());
      final all = await db.loadConversations();
      expect(all.length, equals(1));
      expect(all.single.peerUsername, equals('alice'));
    });

    test('upsertConversation overwrites an existing row', () async {
      await db.upsertConversation(_convo(unread: 0));
      await db.upsertConversation(_convo(unread: 5));
      final all = await db.loadConversations();
      expect(all.single.unreadCount, equals(5));
    });

    test('deleteConversation removes the row and its messages', () async {
      await db.upsertConversation(_convo());
      await db.upsertMessages('c1', [_msg('m1', DateTime.utc(2026, 5, 1))]);
      await db.deleteConversation('c1');
      final all = await db.loadConversations();
      expect(all, isEmpty);
    });

    test('disappearingTtl round-trips (default -1 and an explicit override)',
        () async {
      await db.upsertConversation(_convo()); // default
      await db.upsertConversation(
          _convo(id: 'c2', username: 'bob').copyWith(disappearingTtl: 604800));
      final all = await db.loadConversations();
      expect(all.singleWhere((c) => c.id == 'c1').disappearingTtl, -1);
      expect(all.singleWhere((c) => c.id == 'c2').disappearingTtl, 604800);
    });

    test('clearMessagesForConversation wipes messages but keeps the row',
        () async {
      await db.upsertConversation(_convo());
      await db.upsertMessages('c1', [
        _msg('m1', DateTime.utc(2026, 5, 1)),
        _msg('m2', DateTime.utc(2026, 5, 2)),
      ]);

      await db.clearMessagesForConversation('c1');

      final all = await db.loadConversations();
      expect(all.length, 1, reason: 'the conversation row survives');
      expect(all.single.messages, isEmpty);
    });
  });

  group('AppDatabaseInMemory messages', () {
    late AppDatabaseInMemory db;
    setUp(() async {
      db = AppDatabaseInMemory();
      await db.open(masterKeyHex: 'k');
      await db.upsertConversation(_convo());
    });

    test('upsertMessages appends new messages', () async {
      await db.upsertMessages('c1', [
        _msg('m1', DateTime.utc(2026, 5, 1)),
        _msg('m2', DateTime.utc(2026, 5, 2)),
      ]);
      final all = await db.loadConversations();
      expect(all.single.messages.length, equals(2));
    });

    test('upsertMessages overwrites a message with the same envelopeId', () async {
      await db.upsertMessages('c1', [_msg('m1', DateTime.utc(2026, 5, 1), body: 'first')]);
      await db.upsertMessages('c1', [_msg('m1', DateTime.utc(2026, 5, 2), body: 'rewritten')]);
      final all = await db.loadConversations();
      expect(all.single.messages.length, equals(1));
      expect(all.single.messages.single.body, equals('rewritten'));
    });

    test('deleteMessage removes a single envelope by id', () async {
      await db.upsertMessages('c1', [
        _msg('m1', DateTime.utc(2026, 5, 1)),
        _msg('m2', DateTime.utc(2026, 5, 2)),
      ]);
      await db.deleteMessage('m1');
      final all = await db.loadConversations();
      expect(all.single.messages.map((m) => m.envelopeId), equals(['m2']));
    });

    test('loadConversations returns messages in ascending serverTs order', () async {
      await db.upsertMessages('c1', [
        _msg('m2', DateTime.utc(2026, 5, 2)),
        _msg('m1', DateTime.utc(2026, 5, 1)),
        _msg('m3', DateTime.utc(2026, 5, 3)),
      ]);
      final all = await db.loadConversations();
      expect(
        all.single.messages.map((m) => m.envelopeId).toList(),
        equals(['m1', 'm2', 'm3']),
      );
    });

    test('loadConversations defaults to most-recent 50 + flags hasMore', () async {
      final messages = [
        for (var i = 0; i < 200; i++)
          _msg('m$i', DateTime.utc(2026, 5, 1).add(Duration(minutes: i))),
      ];
      await db.upsertMessages('c1', messages);
      final all = await db.loadConversations();
      expect(all.single.messages.length, equals(50));
      // Newest 50: m150..m199.
      expect(all.single.messages.first.envelopeId, equals('m150'));
      expect(all.single.messages.last.envelopeId, equals('m199'));
      expect(all.single.hasMoreOlderMessages, isTrue);
    });

    test('loadConversations honors messagesPerConversation override', () async {
      final messages = [
        for (var i = 0; i < 10; i++)
          _msg('m$i', DateTime.utc(2026, 5, 1).add(Duration(minutes: i))),
      ];
      await db.upsertMessages('c1', messages);
      final all = await db.loadConversations(messagesPerConversation: 5);
      expect(all.single.messages.length, equals(5));
      expect(all.single.messages.first.envelopeId, equals('m5'));
      expect(all.single.hasMoreOlderMessages, isTrue);
    });

    test('loadConversations sets hasMoreOlderMessages=false when window holds everything', () async {
      await db.upsertMessages('c1', [
        _msg('m1', DateTime.utc(2026, 5, 1)),
        _msg('m2', DateTime.utc(2026, 5, 2)),
      ]);
      final all = await db.loadConversations();
      expect(all.single.messages.length, equals(2));
      expect(all.single.hasMoreOlderMessages, isFalse);
    });
  });

  group('AppDatabaseInMemory hydrate (multi-conversation)', () {
    late AppDatabaseInMemory db;
    setUp(() async {
      db = AppDatabaseInMemory();
      await db.open(masterKeyHex: 'k');
      // Three conversations with different history depths: one well over the
      // page size, one exactly at it, one under. Interleave the upserts so
      // hydrate can't rely on insertion grouping to bucket correctly.
      await db.upsertConversation(_convo(id: 'a', username: 'alice'));
      await db.upsertConversation(_convo(id: 'b', username: 'bob'));
      await db.upsertConversation(_convo(id: 'c', username: 'carol'));
      final base = DateTime.utc(2026, 5, 1);
      await db.upsertMessages('a', [
        for (var i = 0; i < 8; i++)
          _msg('a$i', base.add(Duration(minutes: i)), convoId: 'a'),
      ]);
      await db.upsertMessages('b', [
        for (var i = 0; i < 5; i++)
          _msg('b$i', base.add(Duration(minutes: i)), convoId: 'b'),
      ]);
      await db.upsertMessages('c', [
        for (var i = 0; i < 2; i++)
          _msg('c$i', base.add(Duration(minutes: i)), convoId: 'c'),
      ]);
    });

    test('each conversation hydrates its own newest window, ascending', () async {
      final all = {
        for (final c in await db.loadConversations(messagesPerConversation: 5))
          c.id: c,
      };
      // 'a' has 8 messages → newest 5 (a3..a7) ascending, hasMore true.
      expect(all['a']!.messages.map((m) => m.envelopeId).toList(),
          equals(['a3', 'a4', 'a5', 'a6', 'a7']));
      expect(all['a']!.hasMoreOlderMessages, isTrue);
      // 'b' has exactly 5 → all of them, hasMore false.
      expect(all['b']!.messages.map((m) => m.envelopeId).toList(),
          equals(['b0', 'b1', 'b2', 'b3', 'b4']));
      expect(all['b']!.hasMoreOlderMessages, isFalse);
      // 'c' has 2 → both, hasMore false.
      expect(all['c']!.messages.map((m) => m.envelopeId).toList(),
          equals(['c0', 'c1']));
      expect(all['c']!.hasMoreOlderMessages, isFalse);
    });

    test('last message per conversation is the chronologically newest', () async {
      final all = {
        for (final c in await db.loadConversations(messagesPerConversation: 5))
          c.id: c,
      };
      expect(all['a']!.messages.last.envelopeId, equals('a7'));
      expect(all['b']!.messages.last.envelopeId, equals('b4'));
      expect(all['c']!.messages.last.envelopeId, equals('c1'));
    });
  });

  group('AppDatabaseInMemory loadMessages', () {
    late AppDatabaseInMemory db;
    setUp(() async {
      db = AppDatabaseInMemory();
      await db.open(masterKeyHex: 'k');
      await db.upsertConversation(_convo());
      await db.upsertMessages('c1', [
        for (var i = 0; i < 10; i++)
          _msg('m$i', DateTime.utc(2026, 5, 1).add(Duration(minutes: i))),
      ]);
    });

    test('returns the most recent N when no cursor is given', () async {
      final page = await db.loadMessages('c1', limit: 3);
      expect(page.map((m) => m.envelopeId), equals(['m7', 'm8', 'm9']));
    });

    test('with beforeServerTsMs returns older messages, ascending', () async {
      // Cursor = serverTs of m7 → only m0..m6 are eligible. Limit=3 keeps
      // the newest 3 of those: m4, m5, m6.
      final cursor = DateTime.utc(2026, 5, 1)
          .add(const Duration(minutes: 7))
          .millisecondsSinceEpoch;
      final page = await db.loadMessages(
        'c1',
        limit: 3,
        beforeServerTsMs: cursor,
      );
      expect(page.map((m) => m.envelopeId), equals(['m4', 'm5', 'm6']));
    });

    test('returns empty when conversation has no messages older than cursor', () async {
      final cursor = DateTime.utc(2026, 5, 1).millisecondsSinceEpoch; // before m0
      final page = await db.loadMessages('c1', limit: 50, beforeServerTsMs: cursor);
      expect(page, isEmpty);
    });

    test('returns empty for unknown conversation', () async {
      final page = await db.loadMessages('unknown', limit: 50);
      expect(page, isEmpty);
    });

    test('returns empty when limit <= 0', () async {
      expect(await db.loadMessages('c1', limit: 0), isEmpty);
      expect(await db.loadMessages('c1', limit: -5), isEmpty);
    });
  });

  group('AppDatabaseInMemory trim', () {
    late AppDatabaseInMemory db;
    setUp(() async {
      db = AppDatabaseInMemory();
      await db.open(masterKeyHex: 'k');
      await db.upsertConversation(_convo());
    });

    test('trimMessages removes oldest beyond the keep count', () async {
      await db.upsertMessages('c1', [
        _msg('m1', DateTime.utc(2026, 5, 1)),
        _msg('m2', DateTime.utc(2026, 5, 2)),
        _msg('m3', DateTime.utc(2026, 5, 3)),
      ]);
      await db.trimMessages('c1', keep: 2);
      final all = await db.loadConversations();
      expect(
        all.single.messages.map((m) => m.envelopeId).toList(),
        equals(['m2', 'm3']),
      );
    });

    test('trimMessages is a no-op when count is below the keep threshold', () async {
      await db.upsertMessages('c1', [_msg('m1', DateTime.utc(2026, 5, 1))]);
      await db.trimMessages('c1', keep: 50);
      final all = await db.loadConversations();
      expect(all.single.messages.length, equals(1));
    });

    test('trimMessages is a no-op for an unknown conversation id', () async {
      await db.trimMessages('does-not-exist', keep: 2);
      // Just verify it doesn't throw.
      expect(true, isTrue);
    });
  });

  group('AppDatabaseInMemory deleteMessagesPastLocalRetention', () {
    test('drops messages past the GLOBAL retention (sentTs + global <= now)', () async {
      final db = AppDatabaseInMemory();
      await db.open(masterKeyHex: 'k');
      await db.upsertConversation(_convo()); // no per-conversation override
      await db.upsertMessages('c1', [
        _msg('old', DateTime.utc(2026, 5, 1)),
        _msg('mid', DateTime.utc(2026, 5, 5)),
        _msg('new', DateTime.utc(2026, 5, 9)),
      ]);
      // global = 3 days, now = 5/9 → delete sentTs + 3d <= 5/9 (i.e. sentTs <= 5/6).
      final removed = await db.deleteMessagesPastLocalRetention(
          DateTime.utc(2026, 5, 9), const Duration(days: 3).inSeconds);
      expect(removed, equals(2));
      final all = await db.loadConversations();
      expect(all.single.messages.map((m) => m.envelopeId).toList(), equals(['new']));
    });

    test('shorter per-conversation override beats the global default', () async {
      final db = AppDatabaseInMemory();
      await db.open(masterKeyHex: 'k');
      await db.upsertConversation(
          _convo().copyWith(disappearingTtl: const Duration(days: 1).inSeconds));
      await db.upsertMessages('c1', [
        _msg('twoDaysOld', DateTime.utc(2026, 5, 7)), // +1d = 5/8 <= now → drop
        _msg('fresh', DateTime.utc(2026, 5, 9)), //      +1d = 5/10 > now → keep
      ]);
      // global is long (30d) but the 1d override governs this conversation.
      final removed = await db.deleteMessagesPastLocalRetention(
          DateTime.utc(2026, 5, 9), const Duration(days: 30).inSeconds);
      expect(removed, equals(1));
      final all = await db.loadConversations();
      expect(all.single.messages.map((m) => m.envelopeId).toList(), equals(['fresh']));
    });

    test('no override + null global → no local retention (keeps everything)', () async {
      final db = AppDatabaseInMemory();
      await db.open(masterKeyHex: 'k');
      await db.upsertConversation(_convo());
      await db.upsertMessages('c1', [_msg('keep', DateTime.utc(2020, 1, 1))]);
      final removed =
          await db.deleteMessagesPastLocalRetention(DateTime.utc(2026, 5, 9), null);
      expect(removed, equals(0));
    });

    test('shorter-of-two: local retention drops a message stamped far in the future',
        () async {
      final db = AppDatabaseInMemory();
      await db.open(masterKeyHex: 'k');
      await db.upsertConversation(_convo()); // no override
      // Sender stamped a 30-day expiry, but this device's global retention is 1 day.
      final stampedFar = _msg('staleLocally', DateTime.utc(2026, 5, 7))
          .copyWith(expiresAt: DateTime.utc(2026, 6, 6));
      await db.upsertMessages('c1', [stampedFar]);
      // The sender's timer hasn't fired (6/6 > now), so deleteExpiredMessages keeps it...
      await db.deleteExpiredMessages(DateTime.utc(2026, 5, 9));
      expect((await db.loadConversations()).single.messages.length, equals(1));
      // ...but the shorter local retention (1d: 5/7 + 1d = 5/8 <= 5/9) drops it.
      final removed = await db.deleteMessagesPastLocalRetention(
          DateTime.utc(2026, 5, 9), const Duration(days: 1).inSeconds);
      expect(removed, equals(1));
    });
  });

  group('AppDatabaseInMemory clearAll', () {
    test('removes every conversation and message', () async {
      final db = AppDatabaseInMemory();
      await db.open(masterKeyHex: 'k');
      await db.upsertConversation(_convo(id: 'a'));
      await db.upsertConversation(_convo(id: 'b'));
      await db.upsertMessages('a', [_msg('m1', DateTime.utc(2026, 5, 1), convoId: 'a')]);
      await db.clearAll();
      expect(await db.loadConversations(), isEmpty);
    });
  });

  group('AppDatabaseInMemory crypto state (per-device-pair)', () {
    ConversationCryptoState st(String convoId, String dev, int send) =>
        ConversationCryptoState(
          conversationId: convoId,
          peerDeviceId: dev,
          sendCounter: send,
          sendChainKey: List<int>.filled(32, send),
          recvCounter: 0,
          recvChainKey: List<int>.filled(32, 0),
        );

    test('stores an independent ratchet per peer device', () async {
      final db = AppDatabaseInMemory();
      await db.open(masterKeyHex: 'k');
      await db.saveConversationCryptoState(st('c1', '', 1)); // primary
      await db.saveConversationCryptoState(st('c1', 'dev-2', 2));
      await db.saveConversationCryptoState(st('c1', 'dev-3', 3));

      expect((await db.loadConversationCryptoState('c1'))!.sendCounter, 1);
      expect(
        (await db.loadConversationCryptoState('c1', peerDeviceId: 'dev-2'))!
            .sendCounter,
        2,
      );
      expect(
        (await db.loadConversationCryptoState('c1', peerDeviceId: 'dev-3'))!
            .sendCounter,
        3,
      );
      // A different conversation is isolated.
      expect(await db.loadConversationCryptoState('c2'), isNull);
    });

    test('delete removes every peer-device pair for the conversation', () async {
      final db = AppDatabaseInMemory();
      await db.open(masterKeyHex: 'k');
      await db.saveConversationCryptoState(st('c1', '', 1));
      await db.saveConversationCryptoState(st('c1', 'dev-2', 2));
      await db.saveConversationCryptoState(st('c2', '', 9));

      await db.deleteConversationCryptoState('c1');

      expect(await db.loadConversationCryptoState('c1'), isNull);
      expect(
        await db.loadConversationCryptoState('c1', peerDeviceId: 'dev-2'),
        isNull,
      );
      // The other conversation's ratchet survives.
      expect((await db.loadConversationCryptoState('c2'))!.sendCounter, 9);
    });
  });

  group('AppDatabaseInMemory media fields', () {
    test('upsertMessages persists mediaFilename for file kind', () async {
      final db = AppDatabaseInMemory();
      await db.open(masterKeyHex: 'k');
      await db.upsertConversation(_convo());
      await db.upsertMessages('c1', [
        ChatMessage(
          envelopeId: 'env-file-1',
          conversationId: 'c1',
          senderDeviceId: 'dev-self',
          body: '',
          serverTs: DateTime.utc(2026, 5, 18),
          mine: true,
          kind: MessageKind.file,
          mediaId: 'mid-1',
          mediaKey: const [1, 2, 3],
          mediaSha256: const [4, 5, 6],
          mediaSize: 1024,
          mediaMime: 'application/pdf',
          mediaFilename: 'spec.pdf',
        ),
      ]);
      final loaded = await db.loadMessages('c1', limit: 10);
      expect(loaded.single.mediaFilename, 'spec.pdf');
    });

    test('upsertMessages persists voiceWaveform for voice kind', () async {
      final db = AppDatabaseInMemory();
      await db.open(masterKeyHex: 'k');
      await db.upsertConversation(_convo());
      await db.upsertMessages('c1', [
        ChatMessage(
          envelopeId: 'env-voice-1',
          conversationId: 'c1',
          senderDeviceId: 'dev-self',
          body: '',
          serverTs: DateTime.utc(2026, 5, 21),
          mine: true,
          kind: MessageKind.voice,
          mediaId: 'mid-v',
          mediaKey: const [1],
          mediaSha256: const [2],
          mediaSize: 4096,
          mediaMime: 'audio/mp4',
          voiceWaveform: const [10, 50, 200, 120, 0],
        ),
      ]);
      final loaded = await db.loadMessages('c1', limit: 10);
      expect(loaded.single.voiceWaveform, [10, 50, 200, 120, 0]);
    });
  });

  group('AppDatabaseInMemory deleteFile', () {
    test('clears state and marks the db closed', () async {
      final db = AppDatabaseInMemory();
      await db.open(masterKeyHex: 'k');
      await db.upsertConversation(_convo());
      await db.upsertMessages('c1', [_msg('m1', DateTime.utc(2026, 5, 1))]);

      await db.deleteFile();
      expect(db.isOpen, isFalse);

      // Re-opening starts from a clean slate.
      await db.open(masterKeyHex: 'k');
      expect(await db.loadConversations(), isEmpty);
    });
  });

  group('AppDatabaseInMemory searchMessages', () {
    late AppDatabaseInMemory db;
    final t = DateTime.utc(2026, 6, 1, 12);
    setUp(() async {
      db = AppDatabaseInMemory();
      await db.open(masterKeyHex: 'k');
      await db.upsertMessages('c1', [
        _msg('m1', t, body: 'hello world'),
        _msg('m2', t.add(const Duration(minutes: 1)), body: 'Hello again'),
        _msg('m3', t.add(const Duration(minutes: 2)), body: 'goodbye'),
      ]);
      // Different conversation — must not leak into c1 results.
      await db.upsertMessages(
          'c2', [_msg('o1', t, convoId: 'c2', body: 'hello from c2')]);
    });

    test('matches body case-insensitively, scoped to the conversation', () async {
      final hits = await db.searchMessages('c1', 'hello');
      expect(hits.map((m) => m.envelopeId), equals(['m2', 'm1']));
    });

    test('returns results newest first', () async {
      final hits = await db.searchMessages('c1', 'hello');
      expect(hits.first.envelopeId, 'm2');
      expect(hits.last.envelopeId, 'm1');
    });

    test('the limit keeps the newest matches', () async {
      final hits = await db.searchMessages('c1', 'hello', limit: 1);
      expect(hits.map((m) => m.envelopeId), equals(['m2']));
    });

    test('an empty / whitespace query returns nothing', () async {
      expect(await db.searchMessages('c1', ''), isEmpty);
      expect(await db.searchMessages('c1', '   '), isEmpty);
    });

    test('a non-matching query returns nothing', () async {
      expect(await db.searchMessages('c1', 'zzz'), isEmpty);
    });

    test('excludes non-text messages', () async {
      await db.upsertMessages('c1', [
        ChatMessage(
          envelopeId: 'sys1',
          conversationId: 'c1',
          senderDeviceId: 'd',
          body: 'hello system event',
          serverTs: t.add(const Duration(minutes: 3)),
          mine: false,
          kind: MessageKind.system,
        ),
      ]);
      final hits = await db.searchMessages('c1', 'hello');
      expect(hits.map((m) => m.envelopeId), equals(['m2', 'm1']));
    });
  });

  group('AppDatabaseInMemory conversation pin', () {
    late AppDatabaseInMemory db;
    setUp(() async {
      db = AppDatabaseInMemory();
      await db.open(masterKeyHex: 'k');
    });

    test('pinnedEnvelopeId round-trips through upsert/load', () async {
      await db.upsertConversation(_convo().copyWith(pinnedEnvelopeId: 'm7'));
      final all = await db.loadConversations();
      expect(all.single.pinnedEnvelopeId, equals('m7'));
    });

    test('defaults to null and can be cleared', () async {
      await db.upsertConversation(_convo());
      expect((await db.loadConversations()).single.pinnedEnvelopeId, isNull);
      await db.upsertConversation(_convo().copyWith(pinnedEnvelopeId: 'm1'));
      expect(
          (await db.loadConversations()).single.pinnedEnvelopeId, equals('m1'));
      await db.upsertConversation(_convo().copyWith(pinnedEnvelopeId: null));
      expect((await db.loadConversations()).single.pinnedEnvelopeId, isNull);
    });
  });
}
