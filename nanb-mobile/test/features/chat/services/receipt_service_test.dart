import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/core/db/app_database.dart';
import 'package:nanb_chat/core/secure_storage/secure_storage.dart';
import 'package:nanb_chat/features/chat/models/chat_message.dart';
import 'package:nanb_chat/features/chat/models/conversation.dart';
import 'package:nanb_chat/features/chat/models/message_control.dart';
import 'package:nanb_chat/features/chat/models/message_kind.dart';
import 'package:nanb_chat/features/chat/services/notifier_service_host.dart';
import 'package:nanb_chat/features/chat/services/receipt_service.dart';
import 'package:nanb_chat/features/chat/services/transport_receipt_log.dart';

const _convoId = '1to1:me:bob';

class _FakeDb implements AppDatabase {
  final stored = <String, ChatMessage>{};

  @override
  Future<void> upsertMessages(
      String conversationId, List<ChatMessage> messages) async {
    for (final m in messages) {
      stored[m.envelopeId] = m;
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

class _FakeHost implements NotifierServiceHost {
  _FakeHost(this.convo);

  Conversation? convo;
  @override
  final _FakeDb db = _FakeDb();

  @override
  Conversation? conversation(String id) => convo;

  @override
  void setConversation(String id, Conversation conversation) =>
      convo = conversation;

  @override
  void notifyHost() {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

ChatMessage _mine({String? clientMsgId}) => ChatMessage(
      envelopeId: 'env-1',
      conversationId: _convoId,
      senderDeviceId: 'dev-me',
      body: 'hi',
      serverTs: DateTime.utc(2026, 1, 1),
      mine: true,
      kind: MessageKind.text,
      clientMsgId: clientMsgId,
    );

_FakeHost _hostWith(ChatMessage m) => _FakeHost(Conversation(
      id: _convoId,
      peerUsername: '@bob',
      peerAccountId: 'acc-bob',
      peerDeviceId: 'dev-bob',
      peerIdentityPubKey: const [1],
      messages: [m],
      unreadCount: 0,
    ));

Future<void> _apply(_FakeHost host, ReceiptKind kind) =>
    ReceiptService(host).applyReceipt(_convoId, kind, ['env-1']);

void main() {
  group('ReceiptService.applyReceipt timestamps', () {
    test('a delivered receipt records when it was delivered', () async {
      final host = _hostWith(_mine());

      await _apply(host, ReceiptKind.delivered);

      expect(host.convo!.messages.single.deliveredAt, isNotNull);
    });

    test('a delivered receipt does not record a read time', () async {
      final host = _hostWith(_mine());

      await _apply(host, ReceiptKind.delivered);

      expect(host.convo!.messages.single.readAt, isNull);
    });

    test('a read receipt records when it was read', () async {
      final host = _hostWith(_mine());

      await _apply(host, ReceiptKind.read);

      expect(host.convo!.messages.single.readAt, isNotNull);
    });

    test('a read receipt also fills in a missing delivered time', () async {
      final host = _hostWith(_mine());

      await _apply(host, ReceiptKind.read);

      expect(host.convo!.messages.single.deliveredAt, isNotNull);
    });

    test('a late delivered receipt keeps the read status', () async {
      final host = _hostWith(_mine());
      await _apply(host, ReceiptKind.read);
      final readAt = host.convo!.messages.single.readAt;

      await _apply(host, ReceiptKind.delivered);

      expect(host.convo!.messages.single.readAt, readAt);
    });

    test('a receipt can name the message by its client message id', () async {
      // A fan-out mints one envelope id per device and the sender keeps only
      // one, so the client id is the only name that survives a resend.
      final host = _hostWith(_mine(clientMsgId: 'cid-1'));

      await ReceiptService(host)
          .applyReceipt(_convoId, ReceiptKind.delivered, ['cid-1']);

      expect(host.convo!.messages.single.deliveryStatus,
          MessageDeliveryStatus.delivered);
    });

    test('a transport-only receipt still shows the message as delivered',
        () async {
      final host = _hostWith(_mine());
      final log = TransportReceiptLog(storage: SecureStorageInMemory());

      await ReceiptService(host, transportReceipts: log).applyReceipt(
          _convoId, ReceiptKind.delivered, ['env-1'],
          transportOnly: true);

      expect(host.convo!.messages.single.deliveryStatus,
          MessageDeliveryStatus.delivered);
    });

    test('a transport-only receipt is remembered as unconfirmed', () async {
      final host = _hostWith(_mine());
      final log = TransportReceiptLog(storage: SecureStorageInMemory());

      await ReceiptService(host, transportReceipts: log).applyReceipt(
          _convoId, ReceiptKind.delivered, ['env-1'],
          transportOnly: true);

      expect(await log.contains('env-1'), isTrue);
    });

    test('an end-to-end receipt clears the unconfirmed mark', () async {
      final host = _hostWith(_mine());
      final log = TransportReceiptLog(storage: SecureStorageInMemory());
      final service = ReceiptService(host, transportReceipts: log);
      await service.applyReceipt(_convoId, ReceiptKind.delivered, ['env-1'],
          transportOnly: true);

      await service.applyReceipt(_convoId, ReceiptKind.delivered, ['env-1']);

      expect(await log.contains('env-1'), isFalse);
    });

    test('a late transport receipt does not undo an end-to-end one', () async {
      final host = _hostWith(_mine());
      final log = TransportReceiptLog(storage: SecureStorageInMemory());
      final service = ReceiptService(host, transportReceipts: log);
      await service.applyReceipt(_convoId, ReceiptKind.delivered, ['env-1']);

      await service.applyReceipt(_convoId, ReceiptKind.delivered, ['env-1'],
          transportOnly: true);

      expect(await log.contains('env-1'), isFalse);
    });

    test('persists the times', () async {
      final host = _hostWith(_mine());

      await _apply(host, ReceiptKind.read);

      expect(host.db.stored['env-1']!.readAt, isNotNull);
    });
  });
}
