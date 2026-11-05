import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/features/chat/models/group_member.dart';

void main() {
  group('GroupMember', () {
    test('equality is value-based across all fields', () {
      final a = GroupMember(
        accountId: 'acc-1',
        username: '@ada',
        deviceId: 'dev-1',
        identityPubKey: const [1, 2, 3],
        x25519PubKey: const [4, 5, 6],
        isAdmin: true,
        isSelf: false,
      );
      final b = GroupMember(
        accountId: 'acc-1',
        username: '@ada',
        deviceId: 'dev-1',
        identityPubKey: const [1, 2, 3],
        x25519PubKey: const [4, 5, 6],
        isAdmin: true,
        isSelf: false,
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('hashCode differs when accountId differs', () {
      final a = GroupMember(
        accountId: 'acc-1',
        username: '@ada',
        deviceId: 'dev-1',
        identityPubKey: const [1],
        x25519PubKey: const [2],
        isAdmin: false,
        isSelf: false,
      );
      final b = GroupMember(
        accountId: 'acc-2',
        username: '@ada',
        deviceId: 'dev-1',
        identityPubKey: const [1],
        x25519PubKey: const [2],
        isAdmin: false,
        isSelf: false,
      );
      expect(a == b, isFalse);
    });
  });
}
