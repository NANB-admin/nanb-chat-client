import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/core/db/app_database.dart';
import 'package:nanb_chat/features/chat/models/chat_message.dart';
import 'package:nanb_chat/features/chat/models/conversation.dart';
import 'package:nanb_chat/features/chat/models/link_preview.dart';
import 'package:nanb_chat/features/chat/models/message_control.dart';
import 'package:nanb_chat/features/chat/models/message_kind.dart';
import 'package:nanb_chat/features/chat/services/message_edit_service.dart';
import 'package:nanb_chat/features/chat/services/notifier_service_host.dart';

const _convoId = '1to1:me:bob';

class _FakeDb implements AppDatabase {
  final stored = <String, ChatMessage>{};

  @override
  Future<ChatMessage?> getMessage(String envelopeId) async =>
      stored[envelopeId];

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
  final sentControls = <String>[];
  final selfControls = <String>[];
  final myDevices = <String>{'dev-me', 'dev-me-2'};

  @override
  Conversation? conversation(String id) => convo;

  @override
  void setConversation(String id, Conversation conversation) =>
      convo = conversation;

  @override
  Future<T> runLocked<T>(String id, Future<T> Function() body) => body();

  @override
  void notifyHost() {}

  @override
  Future<void> sendControl(String conversationId, String body,
          {String? pushKind,
          String? toDeviceId,
          bool allPeerDevices = false}) async =>
      sentControls.add(body);

  @override
  Future<void> sendSelfControl(String conversationId, String body) async =>
      selfControls.add(body);

  @override
  Future<bool> isMyDeviceWarm(String deviceId, String myDeviceId) async =>
      myDevices.contains(deviceId);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

ChatMessage _msg({
  String id = 'env-1',
  String body = 'hello',
  bool mine = true,
  String sender = 'dev-me',
  MessageKind kind = MessageKind.text,
  Duration age = const Duration(minutes: 1),
  String? outboxId,
  LinkPreview? preview,
}) =>
    ChatMessage(
      envelopeId: id,
      conversationId: _convoId,
      senderDeviceId: sender,
      body: body,
      serverTs: DateTime.now().toUtc().subtract(age),
      mine: mine,
      kind: kind,
      outboxId: outboxId,
      linkPreview: preview,
    );

Conversation _convoWith(List<ChatMessage> messages) => Conversation(
      id: _convoId,
      peerUsername: '@bob',
      peerAccountId: 'acc-bob',
      peerDeviceId: 'dev-bob',
      peerIdentityPubKey: const [1],
      messages: messages,
      unreadCount: 0,
    );

Future<void> _edit(_FakeHost host, ChatMessage target, String text) =>
    MessageEditService(host).edit(
      conversationId: _convoId,
      target: target,
      newText: text,
    );

void main() {
  group('MessageEditService.canEdit', () {
    test('allows our own recent text message', () {
      expect(MessageEditService.canEdit(_msg()), isTrue);
    });

    test('refuses a message we received', () {
      expect(MessageEditService.canEdit(_msg(mine: false)), isFalse);
    });

    test('refuses a message that is not text', () {
      expect(
          MessageEditService.canEdit(_msg(kind: MessageKind.image)), isFalse);
    });

    test('refuses a message older than the edit window', () {
      final old = _msg(age: MessageEditService.editWindow * 2);

      expect(MessageEditService.canEdit(old), isFalse);
    });

    test('refuses a message that has not reached the server yet', () {
      expect(MessageEditService.canEdit(_msg(outboxId: 'out-1')), isFalse);
    });
  });

  group('MessageEditService.edit', () {
    test('replaces the text', () async {
      final host = _FakeHost(_convoWith([_msg()]));

      await _edit(host, _msg(), 'hello there');

      expect(host.convo!.messages.single.body, 'hello there');
    });

    test('marks the message as edited', () async {
      final host = _FakeHost(_convoWith([_msg()]));

      await _edit(host, _msg(), 'hello there');

      expect(host.convo!.messages.single.edited, isTrue);
    });

    test('persists the edit', () async {
      final host = _FakeHost(_convoWith([_msg()]));

      await _edit(host, _msg(), 'hello there');

      expect(host.db.stored['env-1']!.body, 'hello there');
    });

    test('drops the old link card', () async {
      const card = LinkPreview(url: 'https://a.example', title: 'A');
      final target = _msg(body: 'https://a.example', preview: card);
      final host = _FakeHost(_convoWith([target]));

      await _edit(host, target, 'no link now');

      expect(host.convo!.messages.single.linkPreview, isNull);
    });

    test('shares the edit with the peer', () async {
      final host = _FakeHost(_convoWith([_msg()]));

      await _edit(host, _msg(), 'hello there');

      expect(MessageControl.tryDecode(host.sentControls.single)!.editedText,
          'hello there');
    });

    test('shares the edit with our own other devices', () async {
      final host = _FakeHost(_convoWith([_msg()]));

      await _edit(host, _msg(), 'hello there');

      expect(host.selfControls, host.sentControls);
    });

    test('ignores an unchanged text', () async {
      final host = _FakeHost(_convoWith([_msg()]));

      await _edit(host, _msg(), '  hello ');

      expect(host.sentControls, isEmpty);
    });

    test('ignores an empty text', () async {
      final host = _FakeHost(_convoWith([_msg()]));

      await _edit(host, _msg(), '   ');

      expect(host.convo!.messages.single.body, 'hello');
    });

    test('refuses a message past the edit window', () async {
      final old = _msg(age: MessageEditService.editWindow * 2);
      final host = _FakeHost(_convoWith([old]));

      await _edit(host, old, 'late edit');

      expect(host.convo!.messages.single.body, 'hello');
    });
  });

  group('MessageEditService.applyInbound', () {
    MessageControl control({String target = 'env-1'}) =>
        MessageControl.edit(targetEnvelopeId: target, text: 'edited');

    Future<void> apply(_FakeHost host, String from, {String target = 'env-1'}) =>
        MessageEditService(host).applyInbound(
          conversationId: _convoId,
          control: control(target: target),
          senderDeviceId: from,
          myDeviceId: 'dev-me',
        );

    test('applies an edit from the peer who wrote the message', () async {
      final host = _FakeHost(
          _convoWith([_msg(mine: false, sender: 'dev-bob')]));

      await apply(host, 'dev-bob');

      expect(host.convo!.messages.single.body, 'edited');
    });

    test('marks a received edit as edited', () async {
      final host = _FakeHost(
          _convoWith([_msg(mine: false, sender: 'dev-bob')]));

      await apply(host, 'dev-bob');

      expect(host.convo!.messages.single.edited, isTrue);
    });

    test('applies an edit synced from our own other device', () async {
      final host = _FakeHost(_convoWith([_msg()]));

      await apply(host, 'dev-me-2');

      expect(host.convo!.messages.single.body, 'edited');
    });

    test('rejects an edit of our message sent by the peer', () async {
      final host = _FakeHost(_convoWith([_msg()]));

      await apply(host, 'dev-bob');

      expect(host.convo!.messages.single.body, 'hello');
    });

    test('rejects an edit from a device that did not write the message',
        () async {
      final host = _FakeHost(
          _convoWith([_msg(mine: false, sender: 'dev-bob')]));

      await apply(host, 'dev-mallory');

      expect(host.convo!.messages.single.body, 'hello');
    });

    test('ignores an edit of an unknown message', () async {
      final host = _FakeHost(_convoWith([_msg()]));

      await apply(host, 'dev-me-2', target: 'nope');

      expect(host.convo!.messages.single.body, 'hello');
    });
  });
}
