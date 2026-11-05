import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/core/db/app_database.dart';
import 'package:nanb_chat/features/chat/models/chat_message.dart';
import 'package:nanb_chat/features/chat/models/conversation.dart';
import 'package:nanb_chat/features/chat/models/link_preview.dart';
import 'package:nanb_chat/features/chat/models/message_control.dart';
import 'package:nanb_chat/features/chat/models/message_kind.dart';
import 'package:nanb_chat/features/chat/services/link_preview_service.dart';
import 'package:nanb_chat/features/chat/services/notifier_service_host.dart';

const _convoId = '1to1:me:bob';
const _link = 'https://example.com/post';
const _preview = LinkPreview(url: _link, title: 'A post', description: 'About');

/// Stores messages by id; only what the service touches.
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
  var notifies = 0;
  final myDevices = <String>{'dev-me', 'dev-me-2'};

  @override
  Conversation? conversation(String id) => convo;

  @override
  void setConversation(String id, Conversation conversation) =>
      convo = conversation;

  @override
  Future<T> runLocked<T>(String id, Future<T> Function() body) => body();

  @override
  void notifyHost() => notifies++;

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
  String body = 'look $_link ok',
  bool mine = true,
  String sender = 'dev-me',
  MessageKind kind = MessageKind.text,
}) =>
    ChatMessage(
      envelopeId: id,
      conversationId: _convoId,
      senderDeviceId: sender,
      body: body,
      serverTs: DateTime(2026, 1, 1),
      mine: mine,
      kind: kind,
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

LinkPreviewService _service(
  _FakeHost host, {
  Future<LinkPreview?> Function(String)? source,
  bool disabled = false,
}) =>
    LinkPreviewService(host,
        source: () => disabled ? null : (source ?? (_) async => _preview));

MessageControl _control({
  String target = 'env-1',
  LinkPreview preview = _preview,
}) =>
    MessageControl.linkPreview(targetEnvelopeId: target, preview: preview);

void main() {
  group('LinkPreviewService.attachFor', () {
    test('stores the preview of the first link on our message', () async {
      final sent = _msg();
      final host = _FakeHost(_convoWith([sent]));

      await _service(host).attachFor(sent);

      expect(host.convo!.messages.single.linkPreview, _preview);
    });

    test('persists the preview', () async {
      final sent = _msg();
      final host = _FakeHost(_convoWith([sent]));

      await _service(host).attachFor(sent);

      expect(host.db.stored['env-1']!.linkPreview, _preview);
    });

    test('asks for the first link when there are several', () async {
      final sent = _msg(body: 'a https://one.example b https://two.example');
      final host = _FakeHost(_convoWith([sent]));
      final asked = <String>[];

      await _service(host, source: (u) async {
        asked.add(u);
        return _preview;
      }).attachFor(sent);

      expect(asked, ['https://one.example']);
    });

    test('shares the preview with the peer', () async {
      final sent = _msg();
      final host = _FakeHost(_convoWith([sent]));

      await _service(host).attachFor(sent);

      expect(MessageControl.tryDecode(host.sentControls.single)!.linkPreview,
          _preview);
    });

    test('shares the preview with our own other devices', () async {
      final sent = _msg();
      final host = _FakeHost(_convoWith([sent]));

      await _service(host).attachFor(sent);

      expect(host.selfControls, host.sentControls);
    });

    test('does nothing when previews are off', () async {
      final sent = _msg();
      final host = _FakeHost(_convoWith([sent]));

      await _service(host, disabled: true).attachFor(sent);

      expect(host.sentControls, isEmpty);
    });

    test('does nothing for a message with no link', () async {
      final sent = _msg(body: 'just text');
      final host = _FakeHost(_convoWith([sent]));
      var asked = false;

      await _service(host, source: (_) async {
        asked = true;
        return _preview;
      }).attachFor(sent);

      expect(asked, isFalse);
    });

    test('does nothing for a message we received', () async {
      final received = _msg(mine: false, sender: 'dev-bob');
      final host = _FakeHost(_convoWith([received]));
      var asked = false;

      await _service(host, source: (_) async {
        asked = true;
        return _preview;
      }).attachFor(received);

      expect(asked, isFalse);
    });

    test('does nothing for a non-text message', () async {
      final photo = _msg(kind: MessageKind.image);
      final host = _FakeHost(_convoWith([photo]));
      var asked = false;

      await _service(host, source: (_) async {
        asked = true;
        return _preview;
      }).attachFor(photo);

      expect(asked, isFalse);
    });

    test('sends nothing when the fetch finds no preview', () async {
      final sent = _msg();
      final host = _FakeHost(_convoWith([sent]));

      await _service(host, source: (_) async => null).attachFor(sent);

      expect(host.sentControls, isEmpty);
    });

    test('swallows a fetch that throws', () async {
      final sent = _msg();
      final host = _FakeHost(_convoWith([sent]));

      await _service(host, source: (_) async => throw StateError('boom'))
          .attachFor(sent);

      expect(host.sentControls, isEmpty);
    });
  });

  group('LinkPreviewService.applyInbound', () {
    Future<void> apply(
      _FakeHost host, {
      MessageControl? control,
      String from = 'dev-bob',
    }) =>
        _service(host).applyInbound(
          conversationId: _convoId,
          control: control ?? _control(),
          senderDeviceId: from,
          myDeviceId: 'dev-me',
        );

    test("attaches the author's preview to their message", () async {
      final theirs = _msg(mine: false, sender: 'dev-bob');
      final host = _FakeHost(_convoWith([theirs]));

      await apply(host);

      expect(host.convo!.messages.single.linkPreview, _preview);
    });

    test('notifies listeners when it attaches', () async {
      final host =
          _FakeHost(_convoWith([_msg(mine: false, sender: 'dev-bob')]));

      await apply(host);

      expect(host.notifies, 1);
    });

    test('ignores a preview from someone who did not write the message',
        () async {
      final theirs = _msg(mine: false, sender: 'dev-bob');
      final host = _FakeHost(_convoWith([theirs]));

      await apply(host, from: 'dev-mallory');

      expect(host.convo!.messages.single.linkPreview, isNull);
    });

    test("ignores a peer's preview aimed at our own message", () async {
      final mine = _msg(mine: true, sender: 'dev-me');
      final host = _FakeHost(_convoWith([mine]));

      await apply(host, from: 'dev-bob');

      expect(host.convo!.messages.single.linkPreview, isNull);
    });

    test("accepts our other device's preview for our own message", () async {
      final mine = _msg(mine: true, sender: 'dev-me');
      final host = _FakeHost(_convoWith([mine]));

      await apply(host, from: 'dev-me-2');

      expect(host.convo!.messages.single.linkPreview, _preview);
    });

    test('ignores a preview for a link the message does not contain',
        () async {
      final theirs = _msg(mine: false, sender: 'dev-bob');
      final host = _FakeHost(_convoWith([theirs]));
      final fake = _control(
          preview:
              const LinkPreview(url: 'https://evil.example', title: 'Bank'));

      await apply(host, control: fake);

      expect(host.convo!.messages.single.linkPreview, isNull);
    });

    test('ignores a preview for an unknown message', () async {
      final host =
          _FakeHost(_convoWith([_msg(mine: false, sender: 'dev-bob')]));

      await apply(host, control: _control(target: 'env-missing'));

      expect(host.convo!.messages.single.linkPreview, isNull);
    });

    test('updates the stored row when the message is not loaded', () async {
      final host = _FakeHost(_convoWith(const []));
      host.db.stored['env-1'] = _msg(mine: false, sender: 'dev-bob');

      await apply(host);

      expect(host.db.stored['env-1']!.linkPreview, _preview);
    });

    test('does not notify when the message is not loaded', () async {
      final host = _FakeHost(_convoWith(const []));
      host.db.stored['env-1'] = _msg(mine: false, sender: 'dev-bob');

      await apply(host);

      expect(host.notifies, 0);
    });
  });
}
