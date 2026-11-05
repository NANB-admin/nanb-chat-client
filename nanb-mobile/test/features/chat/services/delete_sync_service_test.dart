import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/core/db/app_database.dart';
import 'package:nanb_chat/features/chat/models/chat_message.dart';
import 'package:nanb_chat/features/chat/models/conversation.dart';
import 'package:nanb_chat/features/chat/models/message_control.dart';
import 'package:nanb_chat/features/chat/models/message_kind.dart';
import 'package:nanb_chat/features/chat/services/delete_sync_service.dart';
import 'package:nanb_chat/features/chat/services/notifier_service_host.dart';

const _convoId = '1to1:a:b';
const _otherConvoId = '1to1:a:c';
const _myDevice = 'dev-me';
const _siblingDevice = 'dev-sibling';
const _peerDevice = 'dev-peer';

class _FakeDb implements AppDatabase {
  final stored = <String, ChatMessage>{};

  @override
  Future<ChatMessage?> getMessage(String envelopeId) async => stored[envelopeId];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

class _FakeHost implements NotifierServiceHost {
  _FakeHost(this.convo);

  Conversation? convo;
  @override
  final _FakeDb db = _FakeDb();
  final selfControls = <String>[];
  final peerControls = <String>[];
  bool selfSendThrows = false;

  @override
  Conversation? conversation(String id) => convo;

  @override
  Future<bool> isMyDeviceWarm(String deviceId, String myDeviceId) async =>
      deviceId == myDeviceId || deviceId == _siblingDevice;

  @override
  Future<void> sendControl(String conversationId, String body,
          {String? pushKind,
          String? toDeviceId,
          bool allPeerDevices = false}) async =>
      peerControls.add(body);

  @override
  Future<void> sendSelfControl(String conversationId, String body) async {
    if (selfSendThrows) throw StateError('offline');
    selfControls.add(body);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

ChatMessage _msg(String id,
        {String conversationId = _convoId,
        String? outboxId,
        MessageKind kind = MessageKind.text}) =>
    ChatMessage(
      envelopeId: id,
      conversationId: conversationId,
      senderDeviceId: _peerDevice,
      body: 'hi',
      serverTs: DateTime.utc(2026, 1, 1),
      mine: false,
      outboxId: outboxId,
      kind: kind,
    );

Conversation _convo(List<ChatMessage> messages) => Conversation(
      id: _convoId,
      peerUsername: '@bob',
      peerAccountId: 'acc-bob',
      peerDeviceId: _peerDevice,
      peerIdentityPubKey: const [1],
      messages: messages,
      unreadCount: 0,
    );

class _Harness {
  _Harness(List<ChatMessage> messages) : host = _FakeHost(_convo(messages)) {
    service = DeleteSyncService(
      host,
      deleteMessageLocal: (conversationId, m) async => deleted.add(m.envelopeId),
    );
  }

  final _FakeHost host;
  late final DeleteSyncService service;
  final deleted = <String>[];

  Future<void> inbound(String targetId, String sender,
          {String conversationId = _convoId}) =>
      service.applyInbound(
        conversationId: conversationId,
        control: MessageControl.deleteForMe(targetId),
        senderDeviceId: sender,
        myDeviceId: _myDevice,
      );
}

void main() {
  test('deleteForMe deletes the message on this device', () async {
    final m = _msg('e1');
    final h = _Harness([m]);

    await h.service.deleteForMe(_convoId, m);

    expect(h.deleted, ['e1']);
  });

  test('deleteForMe self-syncs a delete-for-me control naming the message',
      () async {
    final m = _msg('e1');
    final h = _Harness([m]);

    await h.service.deleteForMe(_convoId, m);

    expect(MessageControl.tryDecode(h.host.selfControls.single)!.isDeleteForMe,
        isTrue);
  });

  test('the self-synced control targets the deleted envelope id', () async {
    final m = _msg('e1');
    final h = _Harness([m]);

    await h.service.deleteForMe(_convoId, m);

    expect(
        MessageControl.tryDecode(h.host.selfControls.single)!.targetEnvelopeId,
        'e1');
  });

  test('deleteForMe never sends anything to the peer or group', () async {
    final m = _msg('e1');
    final h = _Harness([m]);

    await h.service.deleteForMe(_convoId, m);

    expect(h.host.peerControls, isEmpty);
  });

  test('an unsent outbox message is deleted but not self-synced', () async {
    final m = _msg('out-1', outboxId: 'out-1');
    final h = _Harness([m]);

    await h.service.deleteForMe(_convoId, m);

    expect(h.host.selfControls, isEmpty);
  });

  test('a local system line is deleted but not self-synced', () async {
    final m = _msg('local-sys-x', kind: MessageKind.system);
    final h = _Harness([m]);

    await h.service.deleteForMe(_convoId, m);

    expect(h.host.selfControls, isEmpty);
  });

  test('a failing self-sync does not stop the local delete', () async {
    final m = _msg('e1');
    final h = _Harness([m]);
    h.host.selfSendThrows = true;

    await h.service.deleteForMe(_convoId, m);

    expect(h.deleted, ['e1']);
  });

  test('an inbound delete from our own sibling device deletes the message',
      () async {
    final h = _Harness([_msg('e1')]);

    await h.inbound('e1', _siblingDevice);

    expect(h.deleted, ['e1']);
  });

  test('an inbound delete from the peer is ignored', () async {
    final h = _Harness([_msg('e1')]);

    await h.inbound('e1', _peerDevice);

    expect(h.deleted, isEmpty);
  });

  test('an inbound delete never re-broadcasts', () async {
    final h = _Harness([_msg('e1')]);

    await h.inbound('e1', _siblingDevice);

    expect(h.host.selfControls, isEmpty);
  });

  test('an inbound delete for an unknown message is a no-op', () async {
    final h = _Harness([_msg('e1')]);

    await h.inbound('missing', _siblingDevice);

    expect(h.deleted, isEmpty);
  });

  test('an inbound delete reaches a stored message outside the loaded window',
      () async {
    final h = _Harness(const []);
    h.host.db.stored['old'] = _msg('old');

    await h.inbound('old', _siblingDevice);

    expect(h.deleted, ['old']);
  });

  test('an inbound delete will not reach a stored message of another chat',
      () async {
    final h = _Harness(const []);
    h.host.db.stored['old'] = _msg('old', conversationId: _otherConvoId);

    await h.inbound('old', _siblingDevice);

    expect(h.deleted, isEmpty);
  });

  test('an inbound delete for an unloaded conversation is a no-op', () async {
    final h = _Harness([_msg('e1')]);
    h.host.convo = null;

    await h.inbound('e1', _siblingDevice);

    expect(h.deleted, isEmpty);
  });

  test('a non delete-for-me control is ignored', () async {
    final h = _Harness([_msg('e1')]);

    await h.service.applyInbound(
      conversationId: _convoId,
      control: const MessageControl.unsend('e1'),
      senderDeviceId: _siblingDevice,
      myDeviceId: _myDevice,
    );

    expect(h.deleted, isEmpty);
  });
}
