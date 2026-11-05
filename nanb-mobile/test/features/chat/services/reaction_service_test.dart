import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/core/db/app_database.dart';
import 'package:nanb_chat/core/push/push_kind.dart';
import 'package:nanb_chat/features/chat/models/chat_message.dart';
import 'package:nanb_chat/features/chat/models/conversation.dart';
import 'package:nanb_chat/features/chat/models/message_control.dart';
import 'package:nanb_chat/features/chat/models/message_kind.dart';
import 'package:nanb_chat/features/chat/services/notifier_service_host.dart';
import 'package:nanb_chat/features/chat/services/reaction_service.dart';

const _convoId = '1to1:me:bob';
const _emoji = '+1';

class _FakeDb implements AppDatabase {
  @override
  Future<void> upsertMessages(
      String conversationId, List<ChatMessage> messages) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

class _FakeHost implements NotifierServiceHost {
  _FakeHost(this.convo);

  Conversation? convo;
  @override
  final _FakeDb db = _FakeDb();
  final pushKinds = <String?>[];

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
  Future<String?> currentAccountId() async => 'acc-me';

  @override
  Future<bool> isMyDeviceWarm(String deviceId, String myDeviceId) async =>
      deviceId == 'dev-me-2';

  @override
  Future<void> sendControl(String conversationId, String body,
          {String? pushKind,
          String? toDeviceId,
          bool allPeerDevices = false}) async =>
      pushKinds.add(pushKind);

  @override
  Future<void> sendSelfControl(String conversationId, String body) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

ChatMessage _msg({bool mine = true, Map<String, String> reactions = const {}}) =>
    ChatMessage(
      envelopeId: 'env-1',
      conversationId: _convoId,
      senderDeviceId: mine ? 'dev-me' : 'dev-bob',
      body: 'hi',
      serverTs: DateTime.utc(2026, 1, 1),
      mine: mine,
      kind: MessageKind.text,
      reactions: reactions,
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

MessageControl _reaction({bool remove = false}) => MessageControl.reaction(
    targetEnvelopeId: 'env-1', emoji: _emoji, remove: remove);

void main() {
  group('ReactionService.react', () {
    test('adding a reaction notifies the peer', () async {
      final host = _hostWith(_msg(mine: false));

      await ReactionService(host).react(
          conversationId: _convoId, targetEnvelopeId: 'env-1', emoji: _emoji);

      expect(host.pushKinds.single, PushKind.reaction);
    });

    test('taking a reaction back stays silent', () async {
      final host = _hostWith(_msg(mine: false, reactions: {'acc-me': _emoji}));

      await ReactionService(host).react(
          conversationId: _convoId, targetEnvelopeId: 'env-1', emoji: _emoji);

      expect(host.pushKinds.single, PushKind.silent);
    });
  });

  group('ReactionService.applyInbound', () {
    Future<List<String>> apply(_FakeHost host, MessageControl c,
        {String from = 'dev-bob'}) async {
      final notified = <String>[];
      await ReactionService(host, onPeerReaction: notified.add).applyInbound(
        conversationId: _convoId,
        control: c,
        senderDeviceId: from,
        myDeviceId: 'dev-me',
      );
      return notified;
    }

    test('the peer reacting to my message raises a notification', () async {
      expect(await apply(_hostWith(_msg()), _reaction()), [_convoId]);
    });

    test('the peer reacting to their own message does not', () async {
      expect(await apply(_hostWith(_msg(mine: false)), _reaction()), isEmpty);
    });

    test('the peer removing a reaction does not', () async {
      final host = _hostWith(_msg(reactions: {'acc-bob': _emoji}));

      expect(await apply(host, _reaction(remove: true)), isEmpty);
    });

    test('repeating the same reaction does not notify again', () async {
      final host = _hostWith(_msg(reactions: {'acc-bob': _emoji}));

      expect(await apply(host, _reaction()), isEmpty);
    });

    test('my own other device reacting does not', () async {
      expect(await apply(_hostWith(_msg()), _reaction(), from: 'dev-me-2'),
          isEmpty);
    });
  });
}
