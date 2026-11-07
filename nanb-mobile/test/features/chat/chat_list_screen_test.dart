import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:nanb_chat/app/providers.dart';
import 'package:nanb_chat/app/router.dart';
import 'package:nanb_chat/app/theme.dart';
import 'package:nanb_chat/core/network/connection_state.dart' as conn;
import 'package:nanb_chat/features/chat/chat_list_screen.dart';
import 'package:nanb_chat/features/chat/conversations_notifier.dart';
import 'package:nanb_chat/features/chat/media_pipeline.dart';
import 'package:nanb_chat/features/chat/models/conversation.dart';
import 'package:nanb_chat/features/chat/models/conversation_kind.dart';
import 'package:nanb_chat/features/chat/widgets/nanb_avatar.dart';
import 'package:nanb_chat/features/chat/widgets/new_chat_or_group_sheet.dart';

class _MockConversationsNotifier extends Mock implements ConversationsNotifier {
  @override
  conn.ConnectionState get connectionState => conn.ConnectionState.connected;

  /// Nothing is stalled in a connected notifier, so the banner renders its
  /// plain label. Non-nullable, so the Mock's null default would throw.
  @override
  String get slowConnectPhases => '';

  /// Nothing failed to drain in tests, so the banner shows its plain label.
  /// Non-nullable, so the Mock's null default would throw.
  @override
  String get catchupDiagnostic => '';

  /// Settled, so the "Catching up…" veil stays off and row assertions see the
  /// list unobstructed. Non-nullable, so the Mock's null default would throw.
  @override
  bool get catchupSettled => true;


  // A mounted, connected notifier has hydrated from disk — so an empty list
  // renders the empty state, not the cold-start loader.
  @override
  bool get hydrated => true;

  // Healthy on-disk DB → no degraded-mode banner.
  @override
  bool get databaseDegradedToMemory => false;

  // The chat list reads the unsorted view (it re-sorts pinned-first itself).
  // Delegate to the mocktail-stubbed [conversations] so each test's existing
  // `when(() => …conversations)` drives both — same content, order irrelevant
  // since the screen re-sorts.
  @override
  List<Conversation> get conversationsUnsorted => conversations;

  @override
  String displayNameFor(Conversation c) => c.kind == ConversationKind.group
      ? (c.groupName ?? '(unnamed group)')
      : c.peerUsername;

  @override
  MediaDescriptor? peerAvatarDescriptor(Conversation c) => null;
}

/// Same as [_MockConversationsNotifier] but still loading from disk — used to
/// assert the chat list shows a spinner instead of flashing the empty state.
class _LoadingMockConversationsNotifier extends _MockConversationsNotifier {
  @override
  bool get hydrated => false;
}

/// The on-disk DB couldn't be opened and the session degraded to in-memory —
/// drives the warning banner.
class _DegradedMockConversationsNotifier extends _MockConversationsNotifier {
  @override
  bool get databaseDegradedToMemory => true;
}

void main() {
  group('ChatListScreen degraded-DB banner', () {
    Future<void> pumpList(
        WidgetTester tester, ConversationsNotifier mock) async {
      when(() => mock.connect()).thenAnswer((_) async {});
      when(() => mock.runDisappearingSweep(any())).thenAnswer((_) async {});
      when(() => mock.conversations).thenReturn([]);
      final router = GoRouter(
        routes: [
          GoRoute(
            path: Routes.chatList,
            builder: (context, state) => const ChatListScreen(),
          ),
        ],
        initialLocation: Routes.chatList,
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            conversationsProvider.overrideWith((ref) => mock),
          ],
          child: MaterialApp.router(
            theme: buildLightTheme(),
            routerConfig: router,
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('shows the warning + RESET when the DB degraded to in-memory',
        (tester) async {
      await pumpList(tester, _DegradedMockConversationsNotifier());
      expect(find.textContaining('Local history unavailable'), findsOneWidget);
      expect(find.text('RESET'), findsOneWidget);
    });

    testWidgets('is absent when the on-disk DB is healthy', (tester) async {
      await pumpList(tester, _MockConversationsNotifier());
      expect(find.textContaining('Local history unavailable'), findsNothing);
      expect(find.text('RESET'), findsNothing);
    });
  });

  group('ChatListScreen FAB Sheet', () {
    testWidgets('FAB opens the new-chat/new-group sheet on tap', (tester) async {
      final mockConversations = _MockConversationsNotifier();

      when(() => mockConversations.connect()).thenAnswer((_) async {});
      when(() => mockConversations.runDisappearingSweep(any())).thenAnswer((_) async {});
      when(() => mockConversations.conversations).thenReturn([]);

      final router = GoRouter(
        routes: [
          GoRoute(
            path: Routes.chatList,
            builder: (context, state) => const ChatListScreen(),
          ),
          GoRoute(
            path: Routes.newChat,
            builder: (context, state) => const Scaffold(body: Text('NewChatScreen')),
          ),
          GoRoute(
            path: NewChatOrGroupSheet.newGroupRoute,
            builder: (context, state) => const Scaffold(body: Text('NewGroupScreen')),
          ),
        ],
        initialLocation: Routes.chatList,
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            conversationsProvider.overrideWith((ref) => mockConversations),
          ],
          child: MaterialApp.router(
            theme: buildLightTheme(),
            routerConfig: router,
          ),
        ),
      );

      await tester.pumpAndSettle();

      // Tap FAB
      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();

      // Sheet should be visible with both options
      expect(find.text('New chat'), findsOneWidget);
      expect(find.text('New group'), findsOneWidget);
    });

    testWidgets('sheet "New chat" tap dismisses sheet and navigates to /chat-list/new', (tester) async {
      final mockConversations = _MockConversationsNotifier();

      when(() => mockConversations.connect()).thenAnswer((_) async {});
      when(() => mockConversations.runDisappearingSweep(any())).thenAnswer((_) async {});
      when(() => mockConversations.conversations).thenReturn([]);

      final router = GoRouter(
        routes: [
          GoRoute(
            path: Routes.chatList,
            builder: (context, state) => const ChatListScreen(),
          ),
          GoRoute(
            path: Routes.newChat,
            builder: (context, state) => const Scaffold(body: Text('NewChatScreen')),
          ),
          GoRoute(
            path: NewChatOrGroupSheet.newGroupRoute,
            builder: (context, state) => const Scaffold(body: Text('NewGroupScreen')),
          ),
        ],
        initialLocation: Routes.chatList,
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            conversationsProvider.overrideWith((ref) => mockConversations),
          ],
          child: MaterialApp.router(
            theme: buildLightTheme(),
            routerConfig: router,
          ),
        ),
      );

      await tester.pumpAndSettle();

      // Tap FAB to open sheet
      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();

      // Tap "New chat"
      await tester.tap(find.text('New chat'));
      await tester.pumpAndSettle();

      // Sheet should be dismissed
      expect(find.text('New chat', skipOffstage: false), findsNothing);
      expect(find.text('New group'), findsNothing);

      // NewChatScreen should be visible
      expect(find.text('NewChatScreen'), findsOneWidget);
    });

    testWidgets('sheet "New group" tap dismisses sheet and navigates to /chat-list/new-group',
        (tester) async {
      final mockConversations = _MockConversationsNotifier();

      when(() => mockConversations.connect()).thenAnswer((_) async {});
      when(() => mockConversations.runDisappearingSweep(any())).thenAnswer((_) async {});
      when(() => mockConversations.conversations).thenReturn([]);

      final router = GoRouter(
        routes: [
          GoRoute(
            path: Routes.chatList,
            builder: (context, state) => const ChatListScreen(),
          ),
          GoRoute(
            path: Routes.newChat,
            builder: (context, state) => const Scaffold(body: Text('NewChatScreen')),
          ),
          GoRoute(
            path: NewChatOrGroupSheet.newGroupRoute,
            builder: (context, state) => const Scaffold(body: Text('NewGroupScreen')),
          ),
        ],
        initialLocation: Routes.chatList,
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            conversationsProvider.overrideWith((ref) => mockConversations),
          ],
          child: MaterialApp.router(
            theme: buildLightTheme(),
            routerConfig: router,
          ),
        ),
      );

      await tester.pumpAndSettle();

      // Tap FAB to open sheet
      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();

      // Tap "New group"
      await tester.tap(find.text('New group'));
      await tester.pumpAndSettle();

      // Sheet should be dismissed
      expect(find.text('New chat'), findsNothing);
      expect(find.text('New group'), findsNothing);

      // NewGroupScreen should be visible
      expect(find.text('NewGroupScreen'), findsOneWidget);
    });
  });

  group('ChatListScreen loading', () {
    testWidgets('shows a loader, not the empty state, until hydrated',
        (tester) async {
      final mockConversations = _LoadingMockConversationsNotifier();

      when(() => mockConversations.connect()).thenAnswer((_) async {});
      when(() => mockConversations.runDisappearingSweep(any()))
          .thenAnswer((_) async {});
      when(() => mockConversations.conversations).thenReturn([]);

      final router = GoRouter(
        routes: [
          GoRoute(
            path: Routes.chatList,
            builder: (context, state) => const ChatListScreen(),
          ),
        ],
        initialLocation: Routes.chatList,
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            conversationsProvider.overrideWith((ref) => mockConversations),
          ],
          child: MaterialApp.router(
            theme: buildLightTheme(),
            routerConfig: router,
          ),
        ),
      );
      // Single pump — the loader is an indeterminate spinner, so pumpAndSettle
      // would never return.
      await tester.pump();

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('No conversations yet'), findsNothing);
    });
  });

  group('ChatListScreen conversation rows', () {
    testWidgets('chat list row renders groupName + group icon for group conversation',
        (tester) async {
      final mockConversations = _MockConversationsNotifier();

      final groupConversation = Conversation(
        id: 'group:test-uuid',
        peerUsername: '@ignored-for-groups',
        peerAccountId: 'account-id',
        peerDeviceId: 'device-id',
        peerIdentityPubKey: [1, 2, 3],
        messages: [],
        unreadCount: 0,
        kind: ConversationKind.group,
        groupName: 'Atlas',
        members: [],
      );

      when(() => mockConversations.connect()).thenAnswer((_) async {});
      when(() => mockConversations.runDisappearingSweep(any())).thenAnswer((_) async {});
      when(() => mockConversations.conversations).thenReturn([groupConversation]);

      final router = GoRouter(
        routes: [
          GoRoute(
            path: Routes.chatList,
            builder: (context, state) => const ChatListScreen(),
          ),
          GoRoute(
            path: Routes.chat,
            builder: (context, state) {
              return const Scaffold(body: Text('ChatScreen'));
            },
          ),
          GoRoute(
            path: Routes.newChat,
            builder: (context, state) => const Scaffold(body: Text('NewChatScreen')),
          ),
          GoRoute(
            path: NewChatOrGroupSheet.newGroupRoute,
            builder: (context, state) => const Scaffold(body: Text('NewGroupScreen')),
          ),
        ],
        initialLocation: Routes.chatList,
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            conversationsProvider.overrideWith((ref) => mockConversations),
          ],
          child: MaterialApp.router(
            theme: buildLightTheme(),
            routerConfig: router,
          ),
        ),
      );

      await tester.pumpAndSettle();

      // Group name should be displayed
      expect(find.text('Atlas'), findsOneWidget);
      // Group icon should be displayed
      expect(find.byIcon(Icons.group_outlined), findsOneWidget);
      // NanbAvatar should not be displayed for group
      expect(find.byType(NanbAvatar), findsNothing);
    });

    testWidgets('pending conversation shows the REQUEST badge; normal one does not',
        (tester) async {
      final mockConversations = _MockConversationsNotifier();

      final pendingConversation = Conversation(
        id: '1to1:a:b',
        peerUsername: '@stranger',
        peerAccountId: 'acc-stranger',
        peerDeviceId: 'dev-stranger',
        peerIdentityPubKey: [1, 2, 3],
        messages: [],
        unreadCount: 1,
        pending: true,
      );
      final normalConversation = Conversation(
        id: '1to1:a:c',
        peerUsername: '@friend',
        peerAccountId: 'acc-friend',
        peerDeviceId: 'dev-friend',
        peerIdentityPubKey: [1, 2, 3],
        messages: [],
        unreadCount: 0,
      );

      when(() => mockConversations.connect()).thenAnswer((_) async {});
      when(() => mockConversations.runDisappearingSweep(any())).thenAnswer((_) async {});
      when(() => mockConversations.conversations)
          .thenReturn([pendingConversation, normalConversation]);

      final router = GoRouter(
        routes: [
          GoRoute(
            path: Routes.chatList,
            builder: (context, state) => const ChatListScreen(),
          ),
        ],
        initialLocation: Routes.chatList,
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            conversationsProvider.overrideWith((ref) => mockConversations),
          ],
          child: MaterialApp.router(
            theme: buildLightTheme(),
            routerConfig: router,
          ),
        ),
      );

      await tester.pumpAndSettle();

      // Exactly one REQUEST badge — on the pending row only.
      expect(find.text('REQUEST'), findsOneWidget);
      expect(find.text('@stranger'), findsOneWidget);
      expect(find.text('@friend'), findsOneWidget);
    });

    testWidgets('chat list row renders peerUsername + avatar for 1:1 conversation',
        (tester) async {
      final mockConversations = _MockConversationsNotifier();

      final oneToOneConversation = Conversation(
        id: '1to1:device-a:device-b',
        peerUsername: '@bob',
        peerAccountId: 'account-id',
        peerDeviceId: 'device-id',
        peerIdentityPubKey: [1, 2, 3],
        messages: [],
        unreadCount: 0,
        kind: ConversationKind.oneToOne,
        members: [],
      );

      when(() => mockConversations.connect()).thenAnswer((_) async {});
      when(() => mockConversations.runDisappearingSweep(any())).thenAnswer((_) async {});
      when(() => mockConversations.conversations).thenReturn([oneToOneConversation]);

      final router = GoRouter(
        routes: [
          GoRoute(
            path: Routes.chatList,
            builder: (context, state) => const ChatListScreen(),
          ),
          GoRoute(
            path: Routes.chat,
            builder: (context, state) {
              return const Scaffold(body: Text('ChatScreen'));
            },
          ),
          GoRoute(
            path: Routes.newChat,
            builder: (context, state) => const Scaffold(body: Text('NewChatScreen')),
          ),
          GoRoute(
            path: NewChatOrGroupSheet.newGroupRoute,
            builder: (context, state) => const Scaffold(body: Text('NewGroupScreen')),
          ),
        ],
        initialLocation: Routes.chatList,
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            conversationsProvider.overrideWith((ref) => mockConversations),
          ],
          child: MaterialApp.router(
            theme: buildLightTheme(),
            routerConfig: router,
          ),
        ),
      );

      await tester.pumpAndSettle();

      // Peer username should be displayed
      expect(find.text('@bob'), findsOneWidget);
      // NanbAvatar should exist for 1:1 row
      expect(find.byType(NanbAvatar), findsWidgets);
      // No group icon for 1:1
      expect(find.byIcon(Icons.group_outlined), findsNothing);
    });
  });

  group('ChatListScreen delete conversation', () {
    late _MockConversationsNotifier mockConversations;

    Widget buildHarness(Conversation conversation) {
      when(() => mockConversations.connect()).thenAnswer((_) async {});
      when(() => mockConversations.runDisappearingSweep(any()))
          .thenAnswer((_) async {});
      when(() => mockConversations.conversations).thenReturn([conversation]);
      when(() => mockConversations.deleteConversationEverywhere(any()))
          .thenAnswer((_) async {});
      final router = GoRouter(
        routes: [
          GoRoute(
            path: Routes.chatList,
            builder: (context, state) => const ChatListScreen(),
          ),
        ],
        initialLocation: Routes.chatList,
      );
      return ProviderScope(
        overrides: [
          conversationsProvider.overrideWith((ref) => mockConversations),
        ],
        child: MaterialApp.router(
          theme: buildLightTheme(),
          routerConfig: router,
        ),
      );
    }

    setUp(() {
      mockConversations = _MockConversationsNotifier();
    });

    final oneToOne = Conversation(
      id: '1to1:a:b',
      peerUsername: '@bob',
      peerAccountId: 'acc-bob',
      peerDeviceId: 'dev-bob',
      peerIdentityPubKey: const [1, 2, 3],
      messages: const [],
      unreadCount: 0,
    );

    testWidgets('long-press opens the action sheet; Delete opens the dialog',
        (tester) async {
      await tester.pumpWidget(buildHarness(oneToOne));
      await tester.pumpAndSettle();

      await tester.longPress(find.text('@bob'));
      await tester.pumpAndSettle();

      // Action sheet with the organize actions + Delete.
      expect(find.text('Pin to top'), findsOneWidget);
      expect(find.text('Mute notifications'), findsOneWidget);
      expect(find.text('Archive'), findsOneWidget);

      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();

      expect(find.text('Delete @bob?'), findsOneWidget);
      verifyNever(() => mockConversations.deleteConversationEverywhere(any()));
    });

    testWidgets('confirming Delete calls notifier.deleteConversationEverywhere',
        (tester) async {
      await tester.pumpWidget(buildHarness(oneToOne));
      await tester.pumpAndSettle();

      await tester.longPress(find.text('@bob'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete')); // sheet item -> dialog
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Delete')); // dialog
      await tester.pumpAndSettle();

      verify(() => mockConversations.deleteConversationEverywhere('1to1:a:b')).called(1);
      expect(find.text('Delete @bob?'), findsNothing);
    });

    testWidgets('pin action calls notifier.setPinned', (tester) async {
      when(() => mockConversations.setPinned(any(), any()))
          .thenAnswer((_) async {});
      await tester.pumpWidget(buildHarness(oneToOne));
      await tester.pumpAndSettle();

      await tester.longPress(find.text('@bob'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Pin to top'));
      await tester.pumpAndSettle();

      verify(() => mockConversations.setPinned('1to1:a:b', true)).called(1);
    });

    testWidgets('archive action calls notifier.setArchived', (tester) async {
      when(() => mockConversations.setArchived(any(), any()))
          .thenAnswer((_) async {});
      await tester.pumpWidget(buildHarness(oneToOne));
      await tester.pumpAndSettle();

      await tester.longPress(find.text('@bob'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Archive'));
      await tester.pumpAndSettle();

      verify(() => mockConversations.setArchived('1to1:a:b', true)).called(1);
    });

    testWidgets('group rows use the group name and member warning',
        (tester) async {
      final group = Conversation(
        id: 'group:uuid',
        peerUsername: '@ignored',
        peerAccountId: 'acc',
        peerDeviceId: 'dev',
        peerIdentityPubKey: const [1, 2, 3],
        messages: const [],
        unreadCount: 0,
        kind: ConversationKind.group,
        groupName: 'Atlas',
        members: const [],
      );
      await tester.pumpWidget(buildHarness(group));
      await tester.pumpAndSettle();

      await tester.longPress(find.text('Atlas'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();

      expect(find.text('Delete Atlas?'), findsOneWidget);
      expect(find.textContaining("You'll leave the group"), findsOneWidget);
    });
  });

  group('ChatListScreen search', () {
    late _MockConversationsNotifier mockConversations;

    Widget buildHarness(List<Conversation> conversations) {
      when(() => mockConversations.connect()).thenAnswer((_) async {});
      when(() => mockConversations.runDisappearingSweep(any()))
          .thenAnswer((_) async {});
      when(() => mockConversations.conversations).thenReturn(conversations);
      final router = GoRouter(
        routes: [
          GoRoute(
            path: Routes.chatList,
            builder: (context, state) => const ChatListScreen(),
          ),
        ],
        initialLocation: Routes.chatList,
      );
      return ProviderScope(
        overrides: [
          conversationsProvider.overrideWith((ref) => mockConversations),
        ],
        child: MaterialApp.router(
          theme: buildLightTheme(),
          routerConfig: router,
        ),
      );
    }

    setUp(() {
      mockConversations = _MockConversationsNotifier();
    });

    final bob = Conversation(
      id: '1to1:a:b',
      peerUsername: '@bob',
      peerAccountId: 'acc-bob',
      peerDeviceId: 'dev-bob',
      peerIdentityPubKey: const [1, 2, 3],
      messages: const [],
      unreadCount: 0,
    );
    final atlas = Conversation(
      id: 'group:uuid',
      peerUsername: '@ignored',
      peerAccountId: 'acc',
      peerDeviceId: 'dev',
      peerIdentityPubKey: const [1, 2, 3],
      messages: const [],
      unreadCount: 0,
      kind: ConversationKind.group,
      groupName: 'Atlas',
      members: const [],
    );

    testWidgets('search icon opens the field; typing filters by name',
        (tester) async {
      await tester.pumpWidget(buildHarness([bob, atlas]));
      await tester.pumpAndSettle();
      expect(find.text('@bob'), findsOneWidget);
      expect(find.text('Atlas'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.search));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'bob');
      await tester.pumpAndSettle();

      expect(find.text('@bob'), findsOneWidget);
      expect(find.text('Atlas'), findsNothing);
    });

    testWidgets('query ignores a leading @ and case', (tester) async {
      await tester.pumpWidget(buildHarness([bob, atlas]));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.search));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '@BOB');
      await tester.pumpAndSettle();

      expect(find.text('@bob'), findsOneWidget);
      expect(find.text('Atlas'), findsNothing);
    });

    testWidgets('no matches shows the empty-search message', (tester) async {
      await tester.pumpWidget(buildHarness([bob, atlas]));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.search));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'zzz');
      await tester.pumpAndSettle();

      expect(find.textContaining('No conversations match'), findsOneWidget);
      expect(find.text('@bob'), findsNothing);
    });

    testWidgets('close clears the query and restores the full list',
        (tester) async {
      await tester.pumpWidget(buildHarness([bob, atlas]));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.search));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'bob');
      await tester.pumpAndSettle();
      expect(find.text('Atlas'), findsNothing);

      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();

      expect(find.byType(TextField), findsNothing);
      expect(find.text('@bob'), findsOneWidget);
      expect(find.text('Atlas'), findsOneWidget);
    });
  });
}
