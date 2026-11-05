import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/features/chat/models/conversation.dart';
import 'package:nanb_chat/features/chat/models/conversation_kind.dart';
import 'package:nanb_chat/features/chat/models/group_member.dart';
import 'package:nanb_chat/features/chat/models/message_control.dart';
import 'package:nanb_chat/features/chat/services/group_disband_service.dart';
import 'package:nanb_chat/features/chat/services/notifier_service_host.dart';

const _groupId = 'group:g1';

/// Records the order of the host calls so the "send first, then delete"
/// ordering is observable.
class _FakeHost implements NotifierServiceHost {
  _FakeHost(this.convo);

  Conversation? convo;
  final calls = <String>[];
  final sentBodies = <String>[];
  final disbanded = <String>[];

  /// How the fake control send behaves: seal immediately and finish (default),
  /// throw before sealing, or never seal.
  Future<void> Function(void Function() onSealed, String body) sendBehaviour =
      (onSealed, body) async => onSealed();

  @override
  Conversation? conversation(String id) => convo;

  @override
  Future<void> sendControlNotifyingSealed(String conversationId, String body,
      {required void Function() onSealed}) {
    calls.add('send');
    sentBodies.add(body);
    return sendBehaviour(onSealed, body);
  }

  @override
  Future<void> disbandGroupLocally(String conversationId) async {
    calls.add('delete');
    disbanded.add(conversationId);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

GroupMember _member(String device,
        {String? account, bool admin = false, bool self = false}) =>
    GroupMember(
      accountId: account ?? 'acc-$device',
      username: device,
      deviceId: device,
      identityPubKey: const [1],
      x25519PubKey: const [2],
      isAdmin: admin,
      isSelf: self,
    );

Conversation _group(List<GroupMember> members) => Conversation(
      id: _groupId,
      peerUsername: '',
      peerAccountId: '',
      peerDeviceId: '',
      peerIdentityPubKey: const [],
      messages: const [],
      unreadCount: 0,
      kind: ConversationKind.group,
      members: members,
    );

Conversation _adminView() => _group([
      _member('dev-me', account: 'A', admin: true, self: true),
      _member('dev-b', account: 'B'),
    ]);

Conversation _memberView() => _group([
      _member('dev-admin', account: 'A', admin: true),
      _member('dev-me', account: 'B', self: true),
      _member('dev-c', account: 'C'),
    ]);

Future<void> _inbound(_FakeHost host, String sender,
        {MessageControl control = const MessageControl.groupDeleted()}) =>
    GroupDisbandService(host).applyInbound(
      conversationId: _groupId,
      control: control,
      senderDeviceId: sender,
    );

void main() {
  group('disband (admin side)', () {
    test('sends a group-deleted control to the group', () async {
      final host = _FakeHost(_adminView());

      await GroupDisbandService(host).disband(_groupId);

      expect(MessageControl.tryDecode(host.sentBodies.single)!.isGroupDeleted,
          isTrue);
    });

    test('deletes the group locally', () async {
      final host = _FakeHost(_adminView());

      await GroupDisbandService(host).disband(_groupId);

      expect(host.disbanded, [_groupId]);
    });

    test('sends the control BEFORE deleting locally', () async {
      final host = _FakeHost(_adminView());

      await GroupDisbandService(host).disband(_groupId);

      expect(host.calls, ['send', 'delete']);
    });

    test('reports success', () async {
      final host = _FakeHost(_adminView());

      expect(await GroupDisbandService(host).disband(_groupId), isTrue);
    });

    test('a failing send still deletes locally', () async {
      final host = _FakeHost(_adminView())
        ..sendBehaviour = (_, _) async => throw StateError('offline');

      await GroupDisbandService(host).disband(_groupId);

      expect(host.disbanded, [_groupId]);
    });

    test('the delete waits until the control is encrypted', () async {
      final host = _FakeHost(_adminView());
      late void Function() seal;
      host.sendBehaviour = (onSealed, _) {
        seal = onSealed;
        return Completer<void>().future; // the submit never finishes
      };

      final done = GroupDisbandService(host).disband(_groupId);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final deletedBeforeSeal = host.disbanded.isNotEmpty;
      seal();
      await done;

      expect(deletedBeforeSeal, isFalse);
    });

    test('the delete does not wait for the network submit to finish', () async {
      final host = _FakeHost(_adminView());
      host.sendBehaviour = (onSealed, _) {
        onSealed();
        return Completer<void>().future; // submit still in flight
      };

      await GroupDisbandService(host).disband(_groupId);

      expect(host.disbanded, [_groupId]);
    });

    test('a send that never encrypts is abandoned after the timeout', () async {
      final host = _FakeHost(_adminView())
        ..sendBehaviour = (_, _) => Completer<void>().future;

      await GroupDisbandService(host,
              sealTimeout: const Duration(milliseconds: 30))
          .disband(_groupId);

      expect(host.disbanded, [_groupId]);
    });

    test('a non-admin member cannot disband', () async {
      final host = _FakeHost(_memberView());

      await GroupDisbandService(host).disband(_groupId);

      expect(host.calls, isEmpty);
    });

    test('a non-admin member gets false', () async {
      final host = _FakeHost(_memberView());

      expect(await GroupDisbandService(host).disband(_groupId), isFalse);
    });

    test('a 1:1 conversation cannot be disbanded', () async {
      final host = _FakeHost(const Conversation(
        id: '1to1:a:b',
        peerUsername: '@bob',
        peerAccountId: 'acc-bob',
        peerDeviceId: 'dev-bob',
        peerIdentityPubKey: [1],
        messages: [],
        unreadCount: 0,
      ));

      expect(await GroupDisbandService(host).disband('1to1:a:b'), isFalse);
    });

    test('an admin who is the last member just deletes', () async {
      final host = _FakeHost(
          _group([_member('dev-me', account: 'A', admin: true, self: true)]));

      await GroupDisbandService(host).disband(_groupId);

      expect(host.disbanded, [_groupId]);
    });

    test('canDisband is true for the admin', () {
      expect(GroupDisbandService(_FakeHost(_adminView())).canDisband(_groupId),
          isTrue);
    });

    test('canDisband is false for a member', () {
      expect(GroupDisbandService(_FakeHost(_memberView())).canDisband(_groupId),
          isFalse);
    });
  });

  group('inbound (receiver side)', () {
    test('a roster admin disbands the group', () async {
      final host = _FakeHost(_memberView());

      await _inbound(host, 'dev-admin');

      expect(host.disbanded, [_groupId]);
    });

    test("the admin's other device (stored non-admin) disbands it too",
        () async {
      final host = _FakeHost(_group([
        _member('dev-admin', account: 'A', admin: true),
        _member('dev-admin2', account: 'A'),
        _member('dev-me', account: 'B', self: true),
      ]));

      await _inbound(host, 'dev-admin2');

      expect(host.disbanded, [_groupId]);
    });

    test('a non-admin member cannot disband the group', () async {
      final host = _FakeHost(_memberView());

      await _inbound(host, 'dev-c');

      expect(host.disbanded, isEmpty);
    });

    test('a device outside the roster cannot disband the group', () async {
      final host = _FakeHost(_memberView());

      await _inbound(host, 'dev-stranger');

      expect(host.disbanded, isEmpty);
    });

    test('a group we do not hold is ignored', () async {
      final host = _FakeHost(null);

      await _inbound(host, 'dev-admin');

      expect(host.disbanded, isEmpty);
    });

    test('a 1:1 conversation is never disbanded by a control', () async {
      final host = _FakeHost(const Conversation(
        id: _groupId,
        peerUsername: '@bob',
        peerAccountId: 'acc-bob',
        peerDeviceId: 'dev-bob',
        peerIdentityPubKey: [1],
        messages: [],
        unreadCount: 0,
      ));

      await _inbound(host, 'dev-bob');

      expect(host.disbanded, isEmpty);
    });

    test('a different control kind is ignored', () async {
      final host = _FakeHost(_memberView());

      await _inbound(host, 'dev-admin',
          control: const MessageControl.unsend('x'));

      expect(host.disbanded, isEmpty);
    });

    test('receiving never sends anything back', () async {
      final host = _FakeHost(_memberView());

      await _inbound(host, 'dev-admin');

      expect(host.sentBodies, isEmpty);
    });
  });
}
