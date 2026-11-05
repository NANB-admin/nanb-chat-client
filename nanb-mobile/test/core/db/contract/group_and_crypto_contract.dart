import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/core/db/app_database.dart';

import 'contract_fixtures.dart';

void runGroupAndCryptoContract(AppDatabase Function() create) {
  group('group members', () {
    test('getGroupMembers is empty when none stored', () async {
      final db = await openDb(create);
      expect(await db.getGroupMembers('g'), isEmpty);
    });

    test('stored members round-trip', () async {
      final db = await openDb(create);
      await db.upsertGroupMembers('g', [member('d1', admin: true)]);
      expect(await db.getGroupMembers('g'), [member('d1', admin: true)]);
    });

    test('members come back in insertion order', () async {
      final db = await openDb(create);
      await db.upsertGroupMembers('g', [member('z'), member('a')]);
      expect((await db.getGroupMembers('g')).map((m) => m.deviceId),
          ['z', 'a']);
    });

    test('upsertGroupMembers replaces the whole membership', () async {
      final db = await openDb(create);
      await db.upsertGroupMembers('g', [member('d1'), member('d2')]);
      await db.upsertGroupMembers('g', [member('d3')]);
      expect((await db.getGroupMembers('g')).map((m) => m.deviceId), ['d3']);
    });

    test('upsertGroupMembers with an empty list clears the membership',
        () async {
      final db = await openDb(create);
      await db.upsertGroupMembers('g', [member('d1')]);
      await db.upsertGroupMembers('g', const []);
      expect(await db.getGroupMembers('g'), isEmpty);
    });

    test('replacing one group leaves another group untouched', () async {
      final db = await openDb(create);
      await db.upsertGroupMembers('g1', [member('d1')]);
      await db.upsertGroupMembers('g2', [member('d2')]);
      await db.upsertGroupMembers('g1', const []);
      expect(await db.getGroupMembers('g2'), hasLength(1));
    });

    test('the same device id can belong to two groups', () async {
      final db = await openDb(create);
      await db.upsertGroupMembers('g1', [member('d1')]);
      await db.upsertGroupMembers('g2', [member('d1')]);
      expect([(await db.getGroupMembers('g1')).length,
          (await db.getGroupMembers('g2')).length], [1, 1]);
    });

    test('deleteGroupMember removes only that device', () async {
      final db = await openDb(create);
      await db.upsertGroupMembers('g', [member('d1'), member('d2')]);
      await db.deleteGroupMember('g', 'd1');
      expect((await db.getGroupMembers('g')).map((m) => m.deviceId), ['d2']);
    });

    test('deleteGroupMember of an unknown device is a no-op', () async {
      final db = await openDb(create);
      await db.upsertGroupMembers('g', [member('d1')]);
      await db.deleteGroupMember('g', 'nope');
      expect(await db.getGroupMembers('g'), hasLength(1));
    });

    test('deleteGroupMember does not affect other groups', () async {
      final db = await openDb(create);
      await db.upsertGroupMembers('g1', [member('d1')]);
      await db.upsertGroupMembers('g2', [member('d1')]);
      await db.deleteGroupMember('g1', 'd1');
      expect(await db.getGroupMembers('g2'), hasLength(1));
    });

    test('deleteGroupMembersForConversation wipes that group', () async {
      final db = await openDb(create);
      await db.upsertGroupMembers('g', [member('d1'), member('d2')]);
      await db.deleteGroupMembersForConversation('g');
      expect(await db.getGroupMembers('g'), isEmpty);
    });

    test('deleteGroupMembersForConversation keeps other groups', () async {
      final db = await openDb(create);
      await db.upsertGroupMembers('g1', [member('d1')]);
      await db.upsertGroupMembers('g2', [member('d2')]);
      await db.deleteGroupMembersForConversation('g1');
      expect(await db.getGroupMembers('g2'), hasLength(1));
    });
  });

  group('updateConversationGroupFields', () {
    test('sets the group name', () async {
      final db = await openDb(create);
      await db.upsertConversation(convo('g'));
      await db.updateConversationGroupFields('g', groupName: 'Team');
      expect((await db.loadConversations()).single.groupName, 'Team');
    });

    test('sets the mls epoch', () async {
      final db = await openDb(create);
      await db.upsertConversation(convo('g'));
      await db.updateConversationGroupFields('g', mlsEpoch: 4);
      expect((await db.loadConversations()).single.mlsEpoch, 4);
    });

    test('updating the name leaves the epoch alone', () async {
      final db = await openDb(create);
      await db.upsertConversation(convo('g', mlsEpoch: 4));
      await db.updateConversationGroupFields('g', groupName: 'Team');
      expect((await db.loadConversations()).single.mlsEpoch, 4);
    });

    test('updating the epoch leaves the name alone', () async {
      final db = await openDb(create);
      await db.upsertConversation(convo('g', groupName: 'Team'));
      await db.updateConversationGroupFields('g', mlsEpoch: 9);
      expect((await db.loadConversations()).single.groupName, 'Team');
    });

    test('passing neither field changes nothing', () async {
      final db = await openDb(create);
      await db.upsertConversation(convo('g', groupName: 'Team', mlsEpoch: 1));
      await db.updateConversationGroupFields('g');
      final c = (await db.loadConversations()).single;
      expect([c.groupName, c.mlsEpoch], ['Team', 1]);
    });

    test('an unknown conversation is not created', () async {
      final db = await openDb(create);
      await db.updateConversationGroupFields('nope', groupName: 'X');
      expect(await db.loadConversations(), isEmpty);
    });

    test('a full upsert with a null name overwrites the stored name',
        () async {
      // Matches AppDatabaseImpl (INSERT OR REPLACE of the whole row).
      final db = await openDb(create);
      await db.upsertConversation(convo('g', groupName: 'Team'));
      await db.upsertConversation(convo('g'));
      expect((await db.loadConversations()).single.groupName, isNull);
    });
  });

  group('group tombstones', () {
    test('loadDeletedGroupIds is empty initially', () async {
      final db = await openDb(create);
      expect(await db.loadDeletedGroupIds(), isEmpty);
    });

    test('markGroupDeleted records the id', () async {
      final db = await openDb(create);
      await db.markGroupDeleted('g');
      expect(await db.loadDeletedGroupIds(), {'g'});
    });

    test('markGroupDeleted is idempotent', () async {
      final db = await openDb(create);
      await db.markGroupDeleted('g');
      await db.markGroupDeleted('g');
      expect(await db.loadDeletedGroupIds(), {'g'});
    });

    test('clearGroupDeleted lifts the tombstone', () async {
      final db = await openDb(create);
      await db.markGroupDeleted('g');
      await db.clearGroupDeleted('g');
      expect(await db.loadDeletedGroupIds(), isEmpty);
    });

    test('clearGroupDeleted leaves other tombstones', () async {
      final db = await openDb(create);
      await db.markGroupDeleted('g1');
      await db.markGroupDeleted('g2');
      await db.clearGroupDeleted('g1');
      expect(await db.loadDeletedGroupIds(), {'g2'});
    });

    test('clearGroupDeleted of an unknown id is a no-op', () async {
      final db = await openDb(create);
      await db.markGroupDeleted('g');
      await db.clearGroupDeleted('nope');
      expect(await db.loadDeletedGroupIds(), {'g'});
    });

    test('a tombstone outlives deleting the conversation', () async {
      final db = await openDb(create);
      await db.upsertConversation(convo('g'));
      await db.markGroupDeleted('g');
      await db.deleteConversation('g');
      expect(await db.loadDeletedGroupIds(), {'g'});
    });
  });

  group('conversation crypto state', () {
    test('load returns null when nothing is stored', () async {
      final db = await openDb(create);
      expect(await db.loadConversationCryptoState('c1'), isNull);
    });

    test('a saved state round-trips', () async {
      final db = await openDb(create);
      await db.saveConversationCryptoState(cryptoState('c1', send: 5));
      expect(await db.loadConversationCryptoState('c1'),
          cryptoState('c1', send: 5));
    });

    test('saving again replaces the state for the same pair', () async {
      final db = await openDb(create);
      await db.saveConversationCryptoState(cryptoState('c1', send: 1));
      await db.saveConversationCryptoState(cryptoState('c1', send: 2));
      expect((await db.loadConversationCryptoState('c1'))!.sendCounter, 2);
    });

    test('the default peer device is the empty string', () async {
      final db = await openDb(create);
      await db.saveConversationCryptoState(cryptoState('c1'));
      expect(await db.loadConversationCryptoState('c1', peerDeviceId: ''),
          isNotNull);
    });

    test('states for different peer devices are independent', () async {
      final db = await openDb(create);
      await db.saveConversationCryptoState(cryptoState('c1', send: 1));
      await db.saveConversationCryptoState(
          cryptoState('c1', peer: 'd2', send: 2));
      expect(
          (await db.loadConversationCryptoState('c1', peerDeviceId: 'd2'))!
              .sendCounter,
          2);
    });

    test('loading an unknown peer device returns null', () async {
      final db = await openDb(create);
      await db.saveConversationCryptoState(cryptoState('c1'));
      expect(await db.loadConversationCryptoState('c1', peerDeviceId: 'x'),
          isNull);
    });

    test('deleteConversationCryptoState removes every peer-device pair',
        () async {
      final db = await openDb(create);
      await db.saveConversationCryptoState(cryptoState('c1'));
      await db.saveConversationCryptoState(cryptoState('c1', peer: 'd2'));
      await db.deleteConversationCryptoState('c1');
      expect([
        await db.loadConversationCryptoState('c1'),
        await db.loadConversationCryptoState('c1', peerDeviceId: 'd2'),
      ], [isNull, isNull]);
    });

    test('deleteConversationCryptoState keeps other conversations', () async {
      final db = await openDb(create);
      await db.saveConversationCryptoState(cryptoState('c1'));
      await db.saveConversationCryptoState(cryptoState('c2'));
      await db.deleteConversationCryptoState('c1');
      expect(await db.loadConversationCryptoState('c2'), isNotNull);
    });

    test('a conversation id that prefixes another is not over-deleted',
        () async {
      final db = await openDb(create);
      await db.saveConversationCryptoState(cryptoState('c1'));
      await db.saveConversationCryptoState(cryptoState('c10'));
      await db.deleteConversationCryptoState('c1');
      expect(await db.loadConversationCryptoState('c10'), isNotNull);
    });
  });
}
