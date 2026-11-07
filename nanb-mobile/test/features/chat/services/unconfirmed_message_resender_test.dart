import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/core/crypto/crypto_bridge.dart';
import 'package:nanb_chat/core/models/envelope.dart' as wire;
import 'package:nanb_chat/core/network/api_client.dart';
import 'package:nanb_chat/core/push/push_kind.dart';
import 'package:nanb_chat/core/secure_storage/secure_storage.dart';
import 'package:nanb_chat/features/chat/models/chat_message.dart';
import 'package:nanb_chat/features/chat/models/conversation.dart';
import 'package:nanb_chat/features/chat/models/conversation_kind.dart';
import 'package:nanb_chat/features/chat/models/crypto_mode.dart';
import 'package:nanb_chat/features/chat/services/notifier_service_host.dart';
import 'package:nanb_chat/features/chat/services/resend_ledger.dart';
import 'package:nanb_chat/features/chat/services/transport_receipt_log.dart';
import 'package:nanb_chat/features/chat/services/unconfirmed_message_resender.dart';

const _convoId = '1to1:me:bob';
final _now = DateTime.utc(2026, 11, 6, 12);

class _FakeCrypto implements CryptoBridge {
  @override
  Future<Set<String>> groupMemberDeviceIds(String groupId) async => const {};

  bool throws = false;
  final encrypted = <String>[];

  @override
  Future<List<int>> encrypt(
      {required String groupId, required List<int> plaintext}) async {
    if (throws) throw StateError('group gone');
    encrypted.add(utf8.decode(plaintext));
    return plaintext;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

class _FakeHost implements NotifierServiceHost {
  _FakeHost(this.convo);

  Conversation convo;
  final submitted = <SubmitMessagePayload>[];
  bool submitThrows = false;

  @override
  Conversation? conversation(String id) => id == convo.id ? convo : null;

  @override
  Iterable<Conversation> allConversations() => [convo];

  @override
  Future<T> runLocked<T>(String id, Future<T> Function() body) => body();

  @override
  Future<String> selfDeviceId() async => 'dev-me';

  @override
  Future<SubmitMessageResult> submit(SubmitMessagePayload payload) async {
    if (submitThrows) throw StateError('offline');
    submitted.add(payload);
    return SubmitMessageResult(envelopeId: 'new', serverTs: _now);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

ChatMessage _mine(
  String id, {
  MessageDeliveryStatus status = MessageDeliveryStatus.sent,
  String senderDeviceId = 'dev-me',
  bool mine = true,
  String? clientMsgId,
  DateTime? serverTs,
  String outboxId = '',
  bool failed = false,
}) =>
    ChatMessage(
      envelopeId: id,
      conversationId: _convoId,
      senderDeviceId: senderDeviceId,
      body: 'body-$id',
      serverTs: serverTs ?? _now.subtract(const Duration(hours: 1)),
      mine: mine,
      clientMsgId: clientMsgId ?? 'cid-$id',
      deliveryStatus: status,
      outboxId: outboxId,
      failed: failed,
    );

Conversation _convo(
  List<ChatMessage> messages, {
  CryptoMode mode = CryptoMode.mls,
  ConversationKind kind = ConversationKind.oneToOne,
  bool blocked = false,
}) =>
    Conversation(
      id: _convoId,
      peerUsername: '@bob',
      peerAccountId: 'acc-bob',
      peerDeviceId: 'dev-bob',
      peerIdentityPubKey: const [1],
      messages: messages,
      unreadCount: 0,
      cryptoMode: mode,
      kind: kind,
      blocked: blocked,
    );

class _Rig {
  _Rig(List<ChatMessage> messages,
      {CryptoMode mode = CryptoMode.mls,
      ConversationKind kind = ConversationKind.oneToOne,
      bool blocked = false,
      Duration settle = Duration.zero})
      : host =
            _FakeHost(_convo(messages, mode: mode, kind: kind, blocked: blocked)),
        log = TransportReceiptLog(storage: SecureStorageInMemory()),
        ledger = ResendLedger(storage: SecureStorageInMemory()) {
    resender = UnconfirmedMessageResender(
      host: host,
      crypto: crypto,
      transportReceipts: log,
      ledger: ledger,
      fanoutRecipients: (_) async => recipients,
      settleDelay: () => settle,
      clock: () => _now,
    );
  }

  final _FakeHost host;
  final _FakeCrypto crypto = _FakeCrypto();
  final TransportReceiptLog log;
  final ResendLedger ledger;
  late final UnconfirmedMessageResender resender;
  List<({String accountId, String deviceId})> recipients = const [
    (accountId: 'acc-bob', deviceId: 'dev-bob'),
  ];
}

void main() {
  group('UnconfirmedMessageResender', () {
    test('re-sends a message the peer never confirmed', () async {
      final rig = _Rig([_mine('a')]);

      await rig.resender.resendNow(_convoId);

      expect(rig.host.submitted.single.recipientDeviceId, 'dev-bob');
    });

    test('submits it as an MLS application envelope', () async {
      final rig = _Rig([_mine('a')]);

      await rig.resender.resendNow(_convoId);

      expect(rig.host.submitted.single.envelopeType,
          wire.EnvelopeType.mlsApplication);
    });

    test('keeps the original client message id so the receiver can dedup',
        () async {
      final rig = _Rig([_mine('a')]);

      await rig.resender.resendNow(_convoId);

      expect(rig.crypto.encrypted.single, startsWith('{"_cid":"cid-a"}'));
    });

    test('does not buzz the recipient again', () async {
      // The original already raised a push; a resend that dedups must be silent.
      final rig = _Rig([_mine('a')]);

      await rig.resender.resendNow(_convoId);

      expect(rig.host.submitted.single.pushKind, PushKind.silent);
    });

    test('sends one ciphertext to every recipient device', () async {
      final rig = _Rig([_mine('a')]);
      rig.recipients = const [
        (accountId: 'acc-bob', deviceId: 'dev-bob'),
        (accountId: 'acc-bob', deviceId: 'dev-bob-2'),
      ];

      await rig.resender.resendNow(_convoId);

      expect(rig.crypto.encrypted, hasLength(1));
      expect(rig.host.submitted.map((p) => p.recipientDeviceId),
          ['dev-bob', 'dev-bob-2']);
    });

    test('re-sends oldest first', () async {
      final rig = _Rig([
        _mine('new', serverTs: _now.subtract(const Duration(minutes: 1))),
        _mine('old', serverTs: _now.subtract(const Duration(hours: 2))),
      ]);

      await rig.resender.resendNow(_convoId);

      expect(rig.crypto.encrypted.first, contains('body-old'));
    });

    test('skips a message confirmed by the recipient', () async {
      final rig = _Rig([_mine('a', status: MessageDeliveryStatus.delivered)]);

      await rig.resender.resendNow(_convoId);

      expect(rig.host.submitted, isEmpty);
    });

    test('re-sends a delivered message confirmed only by the transport',
        () async {
      // The iOS extension acknowledges a push before anything is decrypted, so
      // this tick says nothing about whether the message can be read.
      final rig = _Rig([_mine('a', status: MessageDeliveryStatus.delivered)]);
      await rig.log.add('a');

      await rig.resender.resendNow(_convoId);

      expect(rig.host.submitted, hasLength(1));
    });

    test('skips a message from a sibling device', () async {
      // That device holds the outbox and the group it was sent under.
      final rig = _Rig([_mine('a', senderDeviceId: 'dev-sibling')]);

      await rig.resender.resendNow(_convoId);

      expect(rig.host.submitted, isEmpty);
    });

    test('skips an inbound message', () async {
      final rig = _Rig([_mine('a', mine: false)]);

      await rig.resender.resendNow(_convoId);

      expect(rig.host.submitted, isEmpty);
    });

    test('skips a message still in the outbox', () async {
      // Its own send is still in flight and retried by the outbox path.
      final rig = _Rig([_mine('a', outboxId: 'outbox-a')]);

      await rig.resender.resendNow(_convoId);

      expect(rig.host.submitted, isEmpty);
    });

    test('skips a failed message', () async {
      final rig = _Rig([_mine('a', failed: true)]);

      await rig.resender.resendNow(_convoId);

      expect(rig.host.submitted, isEmpty);
    });

    test('skips a message older than the resend window', () async {
      final rig =
          _Rig([_mine('a', serverTs: _now.subtract(const Duration(days: 15)))]);

      await rig.resender.resendNow(_convoId);

      expect(rig.host.submitted, isEmpty);
    });

    test('caps one run at the newest fifty messages', () async {
      final rig = _Rig([
        for (var i = 0; i < 60; i++)
          _mine('m$i', serverTs: _now.subtract(Duration(minutes: 60 - i))),
      ]);

      await rig.resender.resendNow(_convoId);

      expect(rig.host.submitted, hasLength(50));
      expect(rig.crypto.encrypted.first, contains('body-m10'));
    });

    test('does nothing while the chat is on ratchet', () async {
      final rig = _Rig([_mine('a')], mode: CryptoMode.ratchet);

      await rig.resender.resendNow(_convoId);

      expect(rig.host.submitted, isEmpty);
    });

    test('does nothing for a group chat', () async {
      final rig = _Rig([_mine('a')], kind: ConversationKind.group);

      await rig.resender.resendNow(_convoId);

      expect(rig.host.submitted, isEmpty);
    });

    test('gives up on a message after eight attempts', () async {
      // Bounds a chat that keeps forking: resends must not grow without limit.
      final rig = _Rig([_mine('a')]);

      for (var i = 0; i < 10; i++) {
        await rig.resender.resendNow(_convoId);
      }

      expect(rig.host.submitted, hasLength(8));
    });

    test('does nothing for a contact this user blocked', () async {
      final rig = _Rig([_mine('a')], blocked: true);

      await rig.resender.resendNow(_convoId);

      expect(rig.host.submitted, isEmpty);
    });

    test('a group change is written down before its timer fires', () async {
      // The app can be killed in that window, and the change never recurs.
      final rig = _Rig([_mine('a')], settle: const Duration(hours: 1));

      rig.resender.onGroupChanged(_convoId);
      await pumpEventQueue();
      rig.resender.dispose();

      expect(await rig.ledger.pendingConversations(), {_convoId});
    });

    test('a completed resend clears what was owed', () async {
      final rig = _Rig([_mine('a')]);
      await rig.ledger.markPending(_convoId);

      await rig.resender.resendNow(_convoId);

      expect(await rig.ledger.pendingConversations(), isEmpty);
    });

    test('a failed resend stays owed', () async {
      final rig = _Rig([_mine('a')]);
      rig.crypto.throws = true;
      await rig.ledger.markPending(_convoId);

      await rig.resender.resendNow(_convoId);

      expect(await rig.ledger.pendingConversations(), {_convoId});
    });

    test('a sweep collects a resend owed from before a restart', () async {
      // Sent seconds ago, so only the owed change can explain this resend.
      final rig = _Rig([_mine('a', serverTs: _now)]);
      await rig.ledger.markPending(_convoId);

      await rig.resender.sweep();

      expect(rig.host.submitted, hasLength(1));
    });

    test('a sweep re-sends a message unconfirmed past the first wait', () async {
      final rig = _Rig([_mine('a')]);

      await rig.resender.sweep();

      expect(rig.host.submitted, hasLength(1));
    });

    test('a sweep leaves a message that was only just sent', () async {
      final rig = _Rig([_mine('a', serverTs: _now)]);

      await rig.resender.sweep();

      expect(rig.host.submitted, isEmpty);
    });

    test('a sweep waits out the backoff after an attempt', () async {
      final rig = _Rig([_mine('a')]);
      await rig.resender.sweep();

      await rig.resender.sweep();

      expect(rig.host.submitted, hasLength(1));
    });

    test('a sweep retries once the backoff has passed', () async {
      final rig = _Rig([_mine('a')]);
      await rig.ledger.recordAttempts(
          ['cid-a'], _now.subtract(const Duration(minutes: 11)));

      await rig.resender.sweep();

      expect(rig.host.submitted, hasLength(1));
    });

    test('a sweep stops after its own budget', () async {
      // A peer who is merely offline must not collect a copy per reconnect.
      final rig = _Rig([_mine('a')]);
      for (var i = 0; i < 3; i++) {
        await rig.ledger.recordAttempts(
            ['cid-a'], _now.subtract(const Duration(days: 1)));
      }

      await rig.resender.sweep();

      expect(rig.host.submitted, isEmpty);
    });

    test('a group change can still retry after the sweep budget is spent',
        () async {
      // That peer may come back on a new group, which the old copies can't reach.
      final rig = _Rig([_mine('a')]);
      for (var i = 0; i < 3; i++) {
        await rig.ledger.recordAttempts(['cid-a'], _now);
      }

      await rig.resender.resendNow(_convoId);

      expect(rig.host.submitted, hasLength(1));
    });

    test('attempts count across a restart', () async {
      final storage = SecureStorageInMemory();
      await ResendLedger(storage: storage).recordAttempts(
          [for (var i = 0; i < 8; i++) 'cid-a'], _now);
      final rig = _Rig([_mine('a')]);
      final resender = UnconfirmedMessageResender(
        host: rig.host,
        crypto: rig.crypto,
        transportReceipts: rig.log,
        ledger: ResendLedger(storage: storage),
        fanoutRecipients: (_) async => rig.recipients,
        clock: () => _now,
      );

      await resender.resendNow(_convoId);

      expect(rig.host.submitted, isEmpty);
    });

    test('an encrypt failure sends nothing and does not throw', () async {
      final rig = _Rig([_mine('a')]);
      rig.crypto.throws = true;

      await rig.resender.resendNow(_convoId);

      expect(rig.host.submitted, isEmpty);
    });

    test('a submit failure does not throw', () async {
      final rig = _Rig([_mine('a')]);
      rig.host.submitThrows = true;

      await expectLater(rig.resender.resendNow(_convoId), completes);
    });

    test('a group change triggers a resend after the settle delay', () async {
      final rig = _Rig([_mine('a')]);

      rig.resender.onGroupChanged(_convoId);
      await Future<void>.delayed(const Duration(milliseconds: 5));

      expect(rig.host.submitted, hasLength(1));
    });

    test('a burst of group changes triggers one resend', () async {
      final rig = _Rig([_mine('a')], settle: const Duration(milliseconds: 5));

      rig.resender.onGroupChanged(_convoId);
      rig.resender.onGroupChanged(_convoId);
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(rig.host.submitted, hasLength(1));
    });

    test('dispose cancels a scheduled resend', () async {
      final rig = _Rig([_mine('a')], settle: const Duration(milliseconds: 5));

      rig.resender.onGroupChanged(_convoId);
      rig.resender.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(rig.host.submitted, isEmpty);
    });
  });
}
