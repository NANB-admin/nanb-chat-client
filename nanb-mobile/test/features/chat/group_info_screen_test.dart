import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:nanb_chat/app/providers.dart';
import 'package:nanb_chat/app/router.dart';
import 'package:nanb_chat/app/theme.dart';
import 'package:nanb_chat/features/chat/conversations_notifier.dart';
import 'package:nanb_chat/features/chat/group_info_screen.dart';
import 'package:nanb_chat/features/chat/media_pipeline.dart';
import 'package:nanb_chat/features/chat/models/conversation.dart';
import 'package:nanb_chat/features/chat/models/conversation_kind.dart';
import 'package:nanb_chat/features/chat/models/group_member.dart';
import 'package:nanb_chat/features/chat/models/member_seed.dart';
import 'package:nanb_chat/features/onboarding/widgets/nanb_button.dart';

// ---------------------------------------------------------------------------
// Fake notifier
// ---------------------------------------------------------------------------

class _AddMemberCall {
  const _AddMemberCall({
    required this.conversationId,
    required this.newMember,
  });
  final String conversationId;
  final MemberSeed newMember;
}

class _RemoveMemberCall {
  const _RemoveMemberCall({
    required this.conversationId,
    required this.targetDeviceId,
  });
  final String conversationId;
  final String targetDeviceId;
}

class _FakeNotifier extends ChangeNotifier implements ConversationsNotifier {
  _FakeNotifier({
    required List<Conversation> conversations,
    String selfDevice = 'self-dev',
  })  : _conversations = conversations,
        _selfDevice = selfDevice;

  final List<Conversation> _conversations;
  final String _selfDevice;

  @override
  MediaDescriptor? peerAvatarDescriptor(Conversation c) => null;

  final List<_AddMemberCall> addMemberCalls = [];
  final List<_RemoveMemberCall> removeMemberCalls = [];

  @override
  List<Conversation> get conversations => _conversations;

  @override
  Conversation? byId(String id) {
    try {
      return _conversations.firstWhere((c) => c.id == id);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<String> selfDeviceId() async => _selfDevice;

  @override
  Future<void> addMemberToGroup({
    required String conversationId,
    required MemberSeed newMember,
  }) async {
    addMemberCalls.add(_AddMemberCall(
      conversationId: conversationId,
      newMember: newMember,
    ));
  }

  @override
  Future<void> removeMemberFromGroup({
    required String conversationId,
    required String targetDeviceId,
  }) async {
    removeMemberCalls.add(_RemoveMemberCall(
      conversationId: conversationId,
      targetDeviceId: targetDeviceId,
    ));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

const _kGroupId = 'group:test-uuid';

GroupMember _member({
  required String username,
  required String deviceId,
  bool isAdmin = false,
  bool isSelf = false,
}) =>
    GroupMember(
      accountId: 'acct-$username',
      username: username,
      deviceId: deviceId,
      identityPubKey: const [],
      x25519PubKey: const [],
      isAdmin: isAdmin,
      isSelf: isSelf,
    );

Conversation _groupConv({
  String groupName = 'Atlas',
  List<GroupMember> members = const [],
  int epoch = 7,
}) =>
    Conversation(
      id: _kGroupId,
      peerUsername: '',
      peerAccountId: '',
      peerDeviceId: '',
      peerIdentityPubKey: const [],
      messages: const [],
      unreadCount: 0,
      kind: ConversationKind.group,
      groupName: groupName,
      members: members,
      mlsEpoch: epoch,
    );

Conversation _oneToOneConv({
  required String username,
  required String accountId,
  required String deviceId,
}) =>
    Conversation(
      id: '1to1:$deviceId:self-dev',
      peerUsername: username,
      peerAccountId: accountId,
      peerDeviceId: deviceId,
      peerIdentityPubKey: const [],
      peerX25519PubKey: const [],
      messages: const [],
      unreadCount: 0,
      kind: ConversationKind.oneToOne,
    );

Widget _buildHarness({
  List<Conversation>? allConversations,
  String convoId = _kGroupId,
  _FakeNotifier? fakeNotifier,
}) {
  final fake = fakeNotifier ??
      _FakeNotifier(conversations: allConversations ?? const []);

  final router = GoRouter(
    routes: [
      GoRoute(
        path: Routes.chat,
        builder: (context, state) => Scaffold(
          body: Text('Chat:${state.pathParameters['conversationId']}'),
        ),
      ),
      GoRoute(
        path: Routes.groupInfo,
        builder: (context, state) => GroupInfoScreen(
          conversationId: state.pathParameters['conversationId'],
        ),
      ),
      GoRoute(
        path: Routes.chatList,
        builder: (context, state) => const Scaffold(body: Text('ChatList')),
      ),
    ],
    initialLocation: '/chat/$convoId/group-info',
  );

  return ProviderScope(
    overrides: [
      conversationsProvider.overrideWith((ref) => fake),
    ],
    child: MaterialApp.router(
      theme: buildLightTheme(),
      routerConfig: router,
    ),
  );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('GroupInfoScreen — Task 18: wired state', () {
    testWidgets(
        'renders groupName + member count + epoch from conversation',
        (tester) async {
      final group = _groupConv(
        groupName: 'Atlas',
        epoch: 7,
        members: [
          _member(username: '@ada', deviceId: 'dev-ada', isSelf: true),
          _member(username: '@lin', deviceId: 'dev-lin'),
          _member(username: '@bob', deviceId: 'dev-bob'),
        ],
      );
      await tester.pumpWidget(_buildHarness(allConversations: [group]));
      await tester.pumpAndSettle();

      expect(find.text('Atlas'), findsOneWidget);
      expect(find.textContaining('3 members'), findsOneWidget);
      expect(find.textContaining('epoch 7'), findsOneWidget);
    });

    testWidgets(
        'lists all members with admin badge only for admin member',
        (tester) async {
      final group = _groupConv(
        members: [
          _member(
            username: '@ada',
            deviceId: 'dev-ada',
            isAdmin: true,
            isSelf: true,
          ),
          _member(username: '@lin', deviceId: 'dev-lin'),
        ],
      );
      await tester.pumpWidget(_buildHarness(allConversations: [group]));
      await tester.pumpAndSettle();

      expect(find.text('@ada (you)'), findsOneWidget);
      expect(find.text('@lin'), findsOneWidget);
      expect(find.text('Admin'), findsOneWidget);
    });

    testWidgets(
        'shows "Group not found" when conversationId does not match any convo',
        (tester) async {
      await tester.pumpWidget(_buildHarness(
        allConversations: const [],
        convoId: 'does-not-exist',
      ));
      await tester.pumpAndSettle();

      expect(find.text('Group not found'), findsOneWidget);
    });

    testWidgets(
        'shows "Group not found" when conversation is a 1:1 (not a group)',
        (tester) async {
      final oneToOne = _oneToOneConv(
        username: '@bob',
        accountId: 'acct-bob',
        deviceId: 'dev-bob',
      );
      await tester.pumpWidget(_buildHarness(
        allConversations: [oneToOne],
        convoId: oneToOne.id,
      ));
      await tester.pumpAndSettle();

      expect(find.text('Group not found'), findsOneWidget);
    });
  });

  group('GroupInfoScreen — Task 19: Add member picker', () {
    testWidgets(
        'admin sees Add member row',
        (tester) async {
      final group = _groupConv(
        members: [
          _member(
            username: '@ada',
            deviceId: 'dev-ada',
            isAdmin: true,
            isSelf: true,
          ),
        ],
      );
      await tester.pumpWidget(_buildHarness(allConversations: [group]));
      await tester.pumpAndSettle();

      expect(find.text('Add member'), findsOneWidget);
    });

    testWidgets(
        'non-admin does not see Add member row',
        (tester) async {
      final group = _groupConv(
        members: [
          _member(
            username: '@ada',
            deviceId: 'dev-ada',
            isAdmin: false,
            isSelf: true,
          ),
        ],
      );
      await tester.pumpWidget(_buildHarness(allConversations: [group]));
      await tester.pumpAndSettle();

      expect(find.text('Add member'), findsNothing);
    });

    testWidgets(
        'tapping Add member then selecting a contact calls addMemberToGroup',
        (tester) async {
      final newContact = _oneToOneConv(
        username: '@new',
        accountId: 'new-acc',
        deviceId: 'dev-new',
      );
      final group = _groupConv(
        members: [
          _member(
            username: '@ada',
            deviceId: 'self-dev',
            isAdmin: true,
            isSelf: true,
          ),
        ],
      );
      final fake = _FakeNotifier(
        conversations: [group, newContact],
        selfDevice: 'self-dev',
      );
      await tester.pumpWidget(_buildHarness(fakeNotifier: fake));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Add member'));
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(ValueKey('add-candidate-${newContact.id}')),
      );
      await tester.pumpAndSettle();

      expect(fake.addMemberCalls.single.newMember.username, '@new');
      expect(fake.addMemberCalls.single.conversationId, _kGroupId);
    });
  });

  group('GroupInfoScreen — Task 20: Long-press Remove (admin only)', () {
    testWidgets(
        'admin long-press on non-self member shows Remove popup',
        (tester) async {
      final group = _groupConv(
        members: [
          _member(
            username: '@ada',
            deviceId: 'dev-ada',
            isAdmin: true,
            isSelf: true,
          ),
          _member(username: '@lin', deviceId: 'dev-lin'),
        ],
      );
      await tester.pumpWidget(_buildHarness(allConversations: [group]));
      await tester.pumpAndSettle();

      await tester.longPress(find.text('@lin'));
      await tester.pumpAndSettle();

      expect(find.text('Remove'), findsOneWidget);
    });

    testWidgets(
        'admin long-press on self does not show Remove popup',
        (tester) async {
      final group = _groupConv(
        members: [
          _member(
            username: '@ada',
            deviceId: 'dev-ada',
            isAdmin: true,
            isSelf: true,
          ),
        ],
      );
      await tester.pumpWidget(_buildHarness(allConversations: [group]));
      await tester.pumpAndSettle();

      await tester.longPress(find.text('@ada (you)'));
      await tester.pumpAndSettle();

      expect(find.text('Remove'), findsNothing);
    });

    testWidgets(
        'confirming Remove dialog calls removeMemberFromGroup with target deviceId',
        (tester) async {
      final group = _groupConv(
        members: [
          _member(
            username: '@ada',
            deviceId: 'dev-ada',
            isAdmin: true,
            isSelf: true,
          ),
          _member(username: '@lin', deviceId: 'dev-lin'),
        ],
      );
      final fake = _FakeNotifier(conversations: [group]);
      await tester.pumpWidget(_buildHarness(fakeNotifier: fake));
      await tester.pumpAndSettle();

      // Long-press to get popup menu
      await tester.longPress(find.text('@lin'));
      await tester.pumpAndSettle();

      // Tap "Remove" in popup menu
      await tester.tap(find.text('Remove'));
      await tester.pumpAndSettle();

      // Confirm in AlertDialog — the dialog has its own "Remove" button
      await tester.tap(find.widgetWithText(TextButton, 'Remove'));
      await tester.pumpAndSettle();

      expect(fake.removeMemberCalls.single.targetDeviceId, 'dev-lin');
      expect(fake.removeMemberCalls.single.conversationId, _kGroupId);
    });

    testWidgets(
        'non-admin long-press does not show Remove popup',
        (tester) async {
      final group = _groupConv(
        members: [
          _member(
            username: '@ada',
            deviceId: 'dev-ada',
            isAdmin: false,
            isSelf: true,
          ),
          _member(username: '@bob', deviceId: 'dev-bob'),
        ],
      );
      await tester.pumpWidget(_buildHarness(allConversations: [group]));
      await tester.pumpAndSettle();

      await tester.longPress(find.text('@bob'));
      await tester.pumpAndSettle();

      expect(find.text('Remove'), findsNothing);
    });
  });

  group('GroupInfoScreen — Task 21: Leave group', () {
    testWidgets(
        'Leave group button shows confirmation dialog',
        (tester) async {
      final group = _groupConv(
        members: [
          _member(username: '@ada', deviceId: 'dev-ada', isSelf: true),
        ],
      );
      await tester.pumpWidget(_buildHarness(allConversations: [group]));
      await tester.pumpAndSettle();

      // NanbButton uppercases its label → rendered text is 'LEAVE GROUP'
      await tester.tap(find.widgetWithText(NanbButton, 'LEAVE GROUP'));
      await tester.pumpAndSettle();

      expect(find.text('Leave this group?'), findsOneWidget);
    });

    testWidgets(
        'confirming Leave calls removeMemberFromGroup with self deviceId',
        (tester) async {
      final group = _groupConv(
        members: [
          _member(
            username: '@ada',
            deviceId: 'self-dev',
            isSelf: true,
          ),
        ],
      );
      final fake = _FakeNotifier(
        conversations: [group],
        selfDevice: 'self-dev',
      );
      await tester.pumpWidget(_buildHarness(fakeNotifier: fake));
      await tester.pumpAndSettle();

      // NanbButton uppercases its label → rendered text is 'LEAVE GROUP'
      await tester.tap(find.widgetWithText(NanbButton, 'LEAVE GROUP'));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(TextButton, 'Leave'));
      await tester.pumpAndSettle();

      expect(fake.removeMemberCalls.single.targetDeviceId, 'self-dev');
      expect(fake.removeMemberCalls.single.conversationId, _kGroupId);
    });
  });
}
