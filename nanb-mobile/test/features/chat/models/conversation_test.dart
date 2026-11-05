import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/features/chat/models/conversation.dart';
import 'package:nanb_chat/features/chat/models/conversation_kind.dart';
import 'package:nanb_chat/features/chat/models/group_member.dart';

void main() {
  group('Conversation new group fields', () {
    test('defaults to oneToOne kind with null groupName and empty members', () {
      final c = Conversation(
        id: '1to1:a:b',
        peerUsername: '@bob',
        peerAccountId: 'acc-b',
        peerDeviceId: 'dev-b',
        peerIdentityPubKey: const [1, 2],
        messages: const [],
        unreadCount: 0,
      );
      expect(c.kind, ConversationKind.oneToOne);
      expect(c.groupName, isNull);
      expect(c.members, isEmpty);
      expect(c.mlsEpoch, isNull);
    });

    test('group conversation carries kind, groupName, members, mlsEpoch', () {
      final ada = GroupMember(
        accountId: 'acc-ada',
        username: '@ada',
        deviceId: 'dev-ada',
        identityPubKey: const [1],
        x25519PubKey: const [2],
        isAdmin: true,
        isSelf: true,
      );
      final c = Conversation(
        id: 'group:uuid-1',
        peerUsername: '',
        peerAccountId: '',
        peerDeviceId: '',
        peerIdentityPubKey: const [],
        messages: const [],
        unreadCount: 0,
        kind: ConversationKind.group,
        groupName: 'Atlas',
        members: [ada],
        mlsEpoch: 7,
      );
      expect(c.kind, ConversationKind.group);
      expect(c.groupName, 'Atlas');
      expect(c.members, [ada]);
      expect(c.mlsEpoch, 7);
    });

    test('copyWith updates groupName + mlsEpoch + members independently', () {
      final c0 = Conversation(
        id: 'group:uuid-1',
        peerUsername: '',
        peerAccountId: '',
        peerDeviceId: '',
        peerIdentityPubKey: const [],
        messages: const [],
        unreadCount: 0,
        kind: ConversationKind.group,
        groupName: 'Old',
        members: const [],
        mlsEpoch: 5,
      );
      final c1 = c0.copyWith(groupName: 'New', mlsEpoch: 6);
      expect(c1.groupName, 'New');
      expect(c1.mlsEpoch, 6);
      expect(c1.kind, ConversationKind.group);
    });
  });

  group('disappearingTtl override', () {
    Conversation base() => Conversation(
          id: '1to1:a:b',
          peerUsername: '@bob',
          peerAccountId: 'acc-b',
          peerDeviceId: 'dev-b',
          peerIdentityPubKey: const [1],
          messages: const [],
          unreadCount: 0,
        );

    test('defaults to -1 (follow the global default)', () {
      expect(base().disappearingTtl, -1);
    });

    test('copyWith sets and carries an explicit override', () {
      final c = base().copyWith(disappearingTtl: 86400);
      expect(c.disappearingTtl, 86400);
      // copyWith without the arg leaves it unchanged.
      expect(c.copyWith(unreadCount: 3).disappearingTtl, 86400);
    });

    test('participates in equality / hashCode', () {
      final a = base();
      final b = base().copyWith(disappearingTtl: 604800);
      expect(a == b, isFalse);
      expect(a.hashCode == b.hashCode, isFalse);
      expect(a == base().copyWith(disappearingTtl: -1), isTrue);
    });

    test('muted participates in equality (so mute toggles rebuild)', () {
      final a = base();
      final b = base().copyWith(muted: true);
      expect(a == b, isFalse);
    });
  });

  group('distinctMembers', () {
    GroupMember gm(String acc, String dev,
            {bool isSelf = false, bool isAdmin = false}) =>
        GroupMember(
          accountId: acc,
          username: '@$acc',
          deviceId: dev,
          identityPubKey: const [],
          x25519PubKey: const [],
          isAdmin: isAdmin,
          isSelf: isSelf,
        );

    test('collapses multi-device members to one row per account', () {
      final c = Conversation(
        id: 'group:g',
        peerUsername: '',
        peerAccountId: '',
        peerDeviceId: '',
        peerIdentityPubKey: const [],
        messages: const [],
        unreadCount: 0,
        kind: ConversationKind.group,
        members: [
          gm('me', 'me-1', isSelf: true, isAdmin: true),
          gm('me', 'me-2', isSelf: true), // our 2nd device
          gm('a', 'a-1'),
          gm('a', 'a-2'), // a's 2nd device
          gm('b', 'b-1'),
        ],
      );

      // One entry per account, first-seen order.
      expect(
          c.distinctMembers.map((m) => m.accountId).toList(), ['me', 'a', 'b']);
      // The self/admin row wins for our own account.
      final me = c.distinctMembers.firstWhere((m) => m.accountId == 'me');
      expect(me.deviceId, 'me-1');
      expect(me.isAdmin, isTrue);
      // Raw members untouched — per-device work still needs every leaf.
      expect(c.members.length, 5);
    });
  });

  group('mediaAudienceAccountIds (media download audience)', () {
    GroupMember member(String accountId,
            {String deviceId = 'd', bool isSelf = false}) =>
        GroupMember(
          accountId: accountId,
          username: '@$accountId',
          deviceId: deviceId,
          identityPubKey: const [],
          x25519PubKey: const [],
          isAdmin: false,
          isSelf: isSelf,
        );

    Conversation oneToOne(String peerAccountId) => Conversation(
          id: '1to1:me:$peerAccountId',
          peerUsername: '@peer',
          peerAccountId: peerAccountId,
          peerDeviceId: 'dev-peer',
          peerIdentityPubKey: const [],
          messages: const [],
          unreadCount: 0,
        );

    Conversation group(List<GroupMember> members) => Conversation(
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

    test('1:1 audience is just the peer account', () {
      expect(oneToOne('acc-peer').mediaAudienceAccountIds, ['acc-peer']);
    });

    test('1:1 with no known peer account yields empty (falls back to open)', () {
      expect(oneToOne('').mediaAudienceAccountIds, isEmpty);
    });

    test('group audience is every distinct member account (self included — the '
        'server folds in the uploader and dedupes)', () {
      final c = group([
        member('me', isSelf: true),
        member('acc-x'),
        member('acc-y'),
      ]);
      expect(c.mediaAudienceAccountIds.toSet(), {'me', 'acc-x', 'acc-y'});
    });

    test('a multi-device member counts once (deduped by account)', () {
      final c = group([
        member('me', deviceId: 'me-1', isSelf: true),
        member('acc-x', deviceId: 'x-1'),
        member('acc-x', deviceId: 'x-2'),
      ]);
      final audience = c.mediaAudienceAccountIds;
      expect(audience.where((a) => a == 'acc-x').length, 1);
      expect(audience.toSet(), {'me', 'acc-x'});
    });
  });
}
