import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:nanb_chat/app/providers.dart';
import 'package:nanb_chat/app/router.dart';
import 'package:nanb_chat/app/theme.dart';
import 'package:nanb_chat/features/chat/conversations_notifier.dart';
import 'package:nanb_chat/features/chat/create_group_screen.dart';
import 'package:nanb_chat/features/chat/models/conversation.dart';
import 'package:nanb_chat/features/chat/models/conversation_kind.dart';
import 'package:nanb_chat/features/chat/models/member_seed.dart';

// ---------------------------------------------------------------------------
// Fake notifier
// ---------------------------------------------------------------------------

class _CreateGroupCall {
  const _CreateGroupCall({
    required this.groupName,
    required this.selfUsername,
    required this.initialMembers,
  });
  final String groupName;
  final String selfUsername;
  final List<MemberSeed> initialMembers;
}

class _FakeNotifier extends ChangeNotifier implements ConversationsNotifier {
  _FakeNotifier({required List<Conversation> contacts}) : _contacts = contacts;

  final List<Conversation> _contacts;
  final List<_CreateGroupCall> createGroupCalls = [];

  @override
  List<Conversation> get conversations => _contacts;

  @override
  Conversation? byId(String id) {
    try {
      return _contacts.firstWhere((c) => c.id == id);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<String> createGroup({
    required String groupName,
    required String selfUsername,
    required List<MemberSeed> initialMembers,
  }) async {
    createGroupCalls.add(_CreateGroupCall(
      groupName: groupName,
      selfUsername: selfUsername,
      initialMembers: initialMembers,
    ));
    return 'group:fake-uuid';
  }

  // Remaining ConversationsNotifier members — unused in these tests.
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Builds a minimal 1:1 Conversation. Username like '@a' → id 'a:me'.
/// The full id is '1to1:a:me' so the widget key is 'contact-1to1:a:me'.
Conversation _convo(String username) {
  final handle = username.replaceFirst('@', '');
  return Conversation(
    id: '1to1:$handle:me',
    peerUsername: username,
    peerAccountId: 'acct-$handle',
    peerDeviceId: 'dev-$handle',
    peerIdentityPubKey: const [],
    peerX25519PubKey: const [],
    messages: const [],
    unreadCount: 0,
    kind: ConversationKind.oneToOne,
  );
}

Widget _buildHarness({
  List<Conversation> contacts = const [],
  _FakeNotifier? fakeNotifier,
}) {
  final fake = fakeNotifier ?? _FakeNotifier(contacts: contacts);

  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/create-group',
        builder: (context, state) => const CreateGroupScreen(selfUsername: '@me'),
      ),
      GoRoute(
        path: Routes.chat,
        builder: (context, state) => Scaffold(
          body: Text('ChatThread:${state.pathParameters['conversationId']}'),
        ),
      ),
    ],
    initialLocation: '/create-group',
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
  group('CreateGroupScreen', () {
    testWidgets(
        'Step 1 "Next" is disabled with 0 or 1 selected, enabled at 2',
        (tester) async {
      await tester.pumpWidget(_buildHarness(contacts: [
        _convo('@a'),
        _convo('@b'),
        _convo('@c'),
      ]));
      await tester.pumpAndSettle();

      // 0 selected → disabled
      final nextBtnAtZero = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Next (0)'),
      );
      expect(nextBtnAtZero.onPressed, isNull);

      // Select 1 → still disabled
      await tester.tap(find.byKey(const ValueKey('contact-1to1:a:me')));
      await tester.pump();
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Next (1)'))
            .onPressed,
        isNull,
      );

      // Select 2 → enabled
      await tester.tap(find.byKey(const ValueKey('contact-1to1:b:me')));
      await tester.pump();
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Next (2)'))
            .onPressed,
        isNotNull,
      );
    });

    testWidgets(
        'Step 2 "Create" is disabled until name is non-empty',
        (tester) async {
      await tester.pumpWidget(
          _buildHarness(contacts: [_convo('@a'), _convo('@b')]));
      await tester.pumpAndSettle();

      // Advance to step 2
      await tester.tap(find.byKey(const ValueKey('contact-1to1:a:me')));
      await tester.tap(find.byKey(const ValueKey('contact-1to1:b:me')));
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Next (2)'));
      await tester.pumpAndSettle();

      // Empty name → disabled
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Create'))
            .onPressed,
        isNull,
      );

      // Enter name → enabled
      await tester.enterText(find.byType(TextField), 'Atlas');
      await tester.pump();
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Create'))
            .onPressed,
        isNotNull,
      );
    });

    testWidgets(
        'Tapping Create calls notifier.createGroup with selected members and trimmed name',
        (tester) async {
      final fake = _FakeNotifier(contacts: [_convo('@a'), _convo('@b')]);
      await tester.pumpWidget(_buildHarness(fakeNotifier: fake));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('contact-1to1:a:me')));
      await tester.tap(find.byKey(const ValueKey('contact-1to1:b:me')));
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Next (2)'));
      await tester.pumpAndSettle();

      // Whitespace-padded name — must be trimmed before passing to notifier
      await tester.enterText(find.byType(TextField), '  Atlas  ');
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Create'));
      await tester.pumpAndSettle();

      expect(fake.createGroupCalls.single.groupName, 'Atlas');
      expect(fake.createGroupCalls.single.initialMembers.length, 2);
      expect(fake.createGroupCalls.single.selfUsername, '@me');
    });

    testWidgets(
        'Step 1 shows empty-state message when there are no 1:1 contacts',
        (tester) async {
      await tester.pumpWidget(_buildHarness(contacts: []));
      await tester.pumpAndSettle();

      expect(
        find.text('No contacts yet — add people by username above.'),
        findsOneWidget,
      );
      // The add-by-username affordance is always available, even with no 1:1s.
      expect(find.widgetWithText(FilledButton, 'Add'), findsOneWidget);
    });
  });
}
