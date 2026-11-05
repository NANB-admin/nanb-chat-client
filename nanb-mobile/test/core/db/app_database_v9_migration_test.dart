import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/core/db/app_database.dart';
import 'package:nanb_chat/features/chat/models/conversation.dart';
import 'package:nanb_chat/features/chat/models/conversation_kind.dart';
import 'package:nanb_chat/features/chat/models/group_member.dart';

void main() {
  group('AppDatabase v9 — group members + group fields', () {
    late AppDatabaseInMemory db;

    setUp(() async {
      db = AppDatabaseInMemory();
      await db.open(masterKeyHex: 'unused');
    });

    test('upsertGroupMembers + getGroupMembers round-trips', () async {
      await db.upsertConversation(_groupConvo('g1'));
      final ada = _member('acc-a', '@ada', 'dev-a', isAdmin: true, isSelf: true);
      final lin = _member('acc-l', '@lin', 'dev-l');
      await db.upsertGroupMembers('g1', [ada, lin]);
      final out = await db.getGroupMembers('g1');
      expect(out, [ada, lin]);
    });

    test('upsertGroupMembers replaces previous membership atomically', () async {
      await db.upsertConversation(_groupConvo('g1'));
      await db.upsertGroupMembers('g1', [_member('acc-a', '@a', 'dev-a')]);
      await db.upsertGroupMembers('g1', [_member('acc-b', '@b', 'dev-b')]);
      final out = await db.getGroupMembers('g1');
      expect(out.length, 1);
      expect(out.single.username, '@b');
    });

    test('deleteGroupMember drops one row by deviceId', () async {
      await db.upsertConversation(_groupConvo('g1'));
      await db.upsertGroupMembers('g1', [
        _member('acc-a', '@a', 'dev-a'),
        _member('acc-b', '@b', 'dev-b'),
      ]);
      await db.deleteGroupMember('g1', 'dev-a');
      final out = await db.getGroupMembers('g1');
      expect(out.length, 1);
      expect(out.single.deviceId, 'dev-b');
    });

    test('deleteGroupMembersForConversation wipes all rows for a conversation', () async {
      await db.upsertConversation(_groupConvo('g1'));
      await db.upsertGroupMembers('g1', [_member('acc-a', '@a', 'dev-a')]);
      await db.deleteGroupMembersForConversation('g1');
      final out = await db.getGroupMembers('g1');
      expect(out, isEmpty);
    });

    test('updateConversationGroupFields persists groupName + mlsEpoch', () async {
      await db.upsertConversation(_groupConvo('g1'));
      await db.updateConversationGroupFields('g1', groupName: 'Atlas', mlsEpoch: 7);
      final convos = await db.loadConversations();
      final c = convos.firstWhere((c) => c.id == 'g1');
      expect(c.groupName, 'Atlas');
      expect(c.mlsEpoch, 7);
    });

    test('updateConversationGroupFields preserves prior value when arg is null', () async {
      await db.upsertConversation(_groupConvo('g1'));
      await db.updateConversationGroupFields('g1', groupName: 'Atlas', mlsEpoch: 7);
      await db.updateConversationGroupFields('g1', mlsEpoch: 8);
      final c = (await db.loadConversations()).firstWhere((c) => c.id == 'g1');
      expect(c.groupName, 'Atlas');
      expect(c.mlsEpoch, 8);
    });

    test('loadConversations re-hydrates members + kind from storage', () async {
      await db.upsertConversation(_groupConvo('g1'));
      final ada = _member('acc-a', '@ada', 'dev-a', isAdmin: true);
      await db.upsertGroupMembers('g1', [ada]);
      final convos = await db.loadConversations();
      final c = convos.firstWhere((c) => c.id == 'g1');
      expect(c.kind, ConversationKind.group);
      expect(c.members, [ada]);
    });

    test('deleting a conversation also wipes its group_members', () async {
      await db.upsertConversation(_groupConvo('g1'));
      await db.upsertGroupMembers('g1', [_member('acc-a', '@a', 'dev-a')]);
      await db.deleteConversation('g1');
      final out = await db.getGroupMembers('g1');
      expect(out, isEmpty);
    });
  });
}

Conversation _groupConvo(String id) => Conversation(
      id: id,
      peerUsername: '',
      peerAccountId: '',
      peerDeviceId: '',
      peerIdentityPubKey: const [],
      messages: const [],
      unreadCount: 0,
      kind: ConversationKind.group,
      groupName: 'Init',
      members: const [],
    );

GroupMember _member(String acc, String name, String dev,
        {bool isAdmin = false, bool isSelf = false}) =>
    GroupMember(
      accountId: acc,
      username: name,
      deviceId: dev,
      identityPubKey: const [1, 2, 3],
      x25519PubKey: const [4, 5, 6],
      isAdmin: isAdmin,
      isSelf: isSelf,
    );
