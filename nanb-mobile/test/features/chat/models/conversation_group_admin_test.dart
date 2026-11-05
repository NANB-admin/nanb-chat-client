import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/features/chat/models/conversation.dart';
import 'package:nanb_chat/features/chat/models/conversation_kind.dart';
import 'package:nanb_chat/features/chat/models/group_member.dart';

GroupMember _member(
  String device, {
  String? account,
  bool admin = false,
  bool self = false,
}) =>
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
      id: 'group:g1',
      peerUsername: '',
      peerAccountId: '',
      peerDeviceId: '',
      peerIdentityPubKey: const [],
      messages: const [],
      unreadCount: 0,
      kind: ConversationKind.group,
      members: members,
    );

void main() {
  test('the admin account is an admin', () {
    final c = _group([_member('d1', account: 'A', admin: true)]);

    expect(c.isGroupAdminAccount('A'), isTrue);
  });

  test('a non-admin account is not an admin', () {
    final c = _group([_member('d1', account: 'A', admin: true), _member('d2')]);

    expect(c.isGroupAdminAccount('acc-d2'), isFalse);
  });

  test("an admin's other device (stored non-admin) counts as the admin", () {
    final c = _group([
      _member('d1', account: 'A', admin: true),
      _member('d1b', account: 'A'),
    ]);

    expect(c.isGroupAdminDevice('d1b'), isTrue);
  });

  test('a device missing from the roster is never an admin', () {
    final c = _group([_member('d1', account: 'A', admin: true)]);

    expect(c.isGroupAdminDevice('stranger'), isFalse);
  });

  test('an empty account id is never an admin', () {
    final c = _group([_member('d1', account: '', admin: true)]);

    expect(c.isGroupAdminAccount(''), isFalse);
  });

  test('isSelfGroupAdmin is true on the creating device', () {
    final c =
        _group([_member('d1', account: 'A', admin: true, self: true)]);

    expect(c.isSelfGroupAdmin, isTrue);
  });

  test('isSelfGroupAdmin is true on the admin account\'s other device', () {
    final c = _group([
      _member('d1', account: 'A', admin: true, self: true),
      _member('d1b', account: 'A', self: true),
    ]);

    expect(c.isSelfGroupAdmin, isTrue);
  });

  test('isSelfGroupAdmin is false for an ordinary member', () {
    final c = _group([
      _member('d1', account: 'A', admin: true),
      _member('d2', account: 'B', self: true),
    ]);

    expect(c.isSelfGroupAdmin, isFalse);
  });

  test('a 1:1 conversation is never a group admin context', () {
    const c = Conversation(
      id: '1to1:a:b',
      peerUsername: '@bob',
      peerAccountId: 'acc-bob',
      peerDeviceId: 'dev-bob',
      peerIdentityPubKey: [1],
      messages: [],
      unreadCount: 0,
    );

    expect(c.isSelfGroupAdmin, isFalse);
  });
}
