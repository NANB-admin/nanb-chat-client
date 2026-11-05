import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/core/db/app_database.dart';
import 'package:nanb_chat/features/chat/models/conversation.dart';
import 'package:nanb_chat/features/chat/models/conversation_kind.dart';
import 'package:nanb_chat/features/chat/models/group_member.dart';
import 'package:nanb_chat/features/chat/models/message_control.dart';
import 'package:nanb_chat/features/chat/services/group_avatar_service.dart';
import 'package:nanb_chat/features/chat/services/notifier_service_host.dart';

const _groupId = 'group:g1';
const _photo = '{"mid":"m1"}';

class _FakeDb implements AppDatabase {
  int upserts = 0;

  @override
  Future<void> upsertConversation(Conversation conversation) async =>
      upserts++;

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
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

GroupMember _member(String device, {required bool admin}) => GroupMember(
      accountId: 'acc-$device',
      username: device,
      deviceId: device,
      identityPubKey: const [1],
      x25519PubKey: const [2],
      isAdmin: admin,
      isSelf: false,
    );

Conversation _group({String? avatar}) => Conversation(
      id: _groupId,
      peerUsername: '',
      peerAccountId: '',
      peerDeviceId: '',
      peerIdentityPubKey: const [],
      messages: const [],
      unreadCount: 0,
      kind: ConversationKind.group,
      groupName: 'Team',
      groupAvatar: avatar,
      members: [
        _member('dev-admin', admin: true),
        _member('dev-b', admin: false),
      ],
    );

Conversation _oneToOne() => const Conversation(
      id: '1to1:a:b',
      peerUsername: '@bob',
      peerAccountId: 'acc-bob',
      peerDeviceId: 'dev-bob',
      peerIdentityPubKey: [1],
      messages: [],
      unreadCount: 0,
    );

Future<void> _inbound(
  _FakeHost host,
  MessageControl control,
  String senderDevice, {
  String id = _groupId,
}) =>
    GroupAvatarService(host).applyInbound(
      conversationId: id,
      control: control,
      senderDeviceId: senderDevice,
    );

void main() {
  test("an admin's inbound control sets the group photo", () async {
    final host = _FakeHost(_group());

    await _inbound(
        host, const MessageControl.groupAvatar(avatarJson: _photo), 'dev-admin');

    expect(host.convo!.groupAvatar, _photo);
  });

  test('an inbound control from a non-admin member is ignored', () async {
    final host = _FakeHost(_group());

    await _inbound(
        host, const MessageControl.groupAvatar(avatarJson: _photo), 'dev-b');

    expect(host.convo!.groupAvatar, isNull);
  });

  test('an inbound control from a device outside the group is ignored',
      () async {
    final host = _FakeHost(_group());

    await _inbound(host, const MessageControl.groupAvatar(avatarJson: _photo),
        'dev-stranger');

    expect(host.convo!.groupAvatar, isNull);
  });

  test("an admin's inbound removal clears the photo", () async {
    final host = _FakeHost(_group(avatar: _photo));

    await _inbound(
        host, const MessageControl.groupAvatar(remove: true), 'dev-admin');

    expect(host.convo!.groupAvatar, isNull);
  });

  test('an inbound control never changes a 1:1 conversation', () async {
    final host = _FakeHost(_oneToOne());

    await _inbound(host, const MessageControl.groupAvatar(avatarJson: _photo),
        'dev-bob',
        id: '1to1:a:b');

    expect(host.convo!.groupAvatar, isNull);
  });

  test('setAvatar stores the new photo on the group', () async {
    final host = _FakeHost(_group());

    await GroupAvatarService(host).setAvatar(_groupId, _photo);

    expect(host.convo!.groupAvatar, _photo);
  });

  test('setAvatar persists the conversation', () async {
    final host = _FakeHost(_group());

    await GroupAvatarService(host).setAvatar(_groupId, _photo);

    expect(host.db.upserts, 1);
  });

  test('setAvatar fans the control out to members', () async {
    final host = _FakeHost(_group());

    await GroupAvatarService(host).setAvatar(_groupId, _photo);

    expect(MessageControl.tryDecode(host.sentControls.single)!.groupAvatarJson,
        _photo);
  });

  test('setAvatar self-syncs the control to our own devices', () async {
    final host = _FakeHost(_group());

    await GroupAvatarService(host).setAvatar(_groupId, _photo);

    expect(host.selfControls, hasLength(1));
  });

  test('setAvatar with null sends a removal', () async {
    final host = _FakeHost(_group(avatar: _photo));

    await GroupAvatarService(host).setAvatar(_groupId, null);

    expect(
        MessageControl.tryDecode(host.sentControls.single)!.groupAvatarRemove,
        isTrue);
  });

  test('setAvatar with an unchanged photo sends nothing', () async {
    final host = _FakeHost(_group(avatar: _photo));

    await GroupAvatarService(host).setAvatar(_groupId, _photo);

    expect(host.sentControls, isEmpty);
  });

  test('setAvatar on a 1:1 sends nothing', () async {
    final host = _FakeHost(_oneToOne());

    await GroupAvatarService(host).setAvatar('1to1:a:b', _photo);

    expect(host.sentControls, isEmpty);
  });
}
