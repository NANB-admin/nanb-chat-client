import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:nanb_chat/app/providers.dart';
import 'package:nanb_chat/app/router.dart';
import 'package:nanb_chat/app/theme.dart';
import 'package:nanb_chat/core/models/report_reason.dart';
import 'package:nanb_chat/core/network/connection_state.dart' as conn;
import 'package:nanb_chat/features/chat/chat_thread_screen.dart';
import 'package:nanb_chat/features/chat/conversations_notifier.dart';
import 'package:nanb_chat/features/chat/models/chat_background_override.dart';
import 'package:nanb_chat/features/chat/models/chat_message.dart';
import 'package:nanb_chat/features/chat/media_pipeline.dart';
import 'package:nanb_chat/features/chat/models/conversation.dart';
import 'package:nanb_chat/features/chat/models/conversation_kind.dart';
import 'package:nanb_chat/features/chat/models/group_member.dart';
import 'package:nanb_chat/features/chat/models/message_kind.dart';
import 'package:nanb_chat/features/chat/models/system_event.dart';
import 'package:nanb_chat/features/chat/widgets/chat_atoms.dart';
import 'package:nanb_chat/features/chat/widgets/chat_composer.dart';

// ---------------------------------------------------------------------------
// Fake notifier
// ---------------------------------------------------------------------------

class _FakeNotifier extends ChangeNotifier implements ConversationsNotifier {
  _FakeNotifier({
    required Conversation? conversation,
    bool hydrated = true,
    bool catchupSettled = true,
    conn.ConnectionState connectionState = conn.ConnectionState.connected,
  })  : _conversation = conversation,
        _hydrated = hydrated,
        _catchupSettled = catchupSettled,
        _connectionState = connectionState;

  final Conversation? _conversation;
  final bool _hydrated;
  final bool _catchupSettled;
  final conn.ConnectionState _connectionState;

  @override
  conn.ConnectionState get connectionState => _connectionState;

  /// No stalled start-up phase in tests, so the banner renders its plain
  /// label. Non-nullable, so the Mock's null default would throw.
  @override
  String get slowConnectPhases => '';

  /// Nothing failed to drain in tests, so the banner shows its plain label.
  /// Non-nullable, so the Mock's null default would throw.
  @override
  String get catchupDiagnostic => '';


  @override
  bool get hydrated => _hydrated;

  @override
  bool get catchupSettled => _catchupSettled;

  @override
  Conversation? byId(String id) => _conversation;

  @override
  List<Conversation> get conversations {
    final c = _conversation;
    return c == null ? [] : [c];
  }

  @override
  void markRead(String conversationId) {}

  @override
  ChatBackgroundOverride backgroundOverrideOf(String conversationId) =>
      const ChatBackgroundOverride.useDefault();

  @override
  void setOpenConversation(String? conversationId) {}

  /// Counts how many times the screen drove `connect()` on this instance.
  int connectCalls = 0;

  @override
  Future<void> connect() async {
    connectCalls++;
  }

  final List<String> acceptedRequests = [];
  final List<String> rejectedRequests = [];
  final List<({String id, ReportReason reason, bool alsoBlock})> reports = [];
  bool reportFails = false;

  @override
  Future<void> reportUser(
    String conversationId, {
    required ReportReason reason,
    String? note,
    bool alsoBlock = true,
  }) async {
    if (reportFails) throw Exception('network down');
    reports.add((id: conversationId, reason: reason, alsoBlock: alsoBlock));
  }

  @override
  Future<void> acceptMessageRequest(String conversationId) async {
    acceptedRequests.add(conversationId);
  }

  @override
  Future<void> rejectMessageRequest(String conversationId) async {
    rejectedRequests.add(conversationId);
  }

  @override
  String displayNameFor(Conversation c) => c.groupName ?? c.peerUsername;

  @override
  Future<void> refreshPeerProfile(String conversationId) async {}

  @override
  Future<void> warmUpMlsMigration(String conversationId) async {}

  @override
  bool isPeerTyping(String conversationId) => false;

  @override
  void sendTyping(String conversationId, bool isTyping) {}

  @override
  MediaDescriptor? peerAvatarDescriptor(Conversation c) => null;

  // The thread top bar asks this to decide whether to show the call button.
  @override
  bool isCallable(String conversationId) => false;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

const _kConversationId = 'group:test-uuid';

GroupMember _member({
  required String username,
  required String deviceId,
  bool isSelf = false,
}) =>
    GroupMember(
      accountId: 'acct-$username',
      username: username,
      deviceId: deviceId,
      identityPubKey: const [],
      x25519PubKey: const [],
      isAdmin: false,
      isSelf: isSelf,
    );

ChatMessage _systemMsg({
  required String body,
  DateTime? ts,
}) =>
    ChatMessage(
      envelopeId: 'env-system',
      conversationId: _kConversationId,
      senderDeviceId: 'server',
      body: body,
      serverTs: ts ?? DateTime(2026, 1, 1, 10, 0),
      mine: false,
      kind: MessageKind.system,
    );

ChatMessage _textMsg({
  required String senderDeviceId,
  required String body,
  bool mine = false,
  String? envelopeId,
  DateTime? ts,
}) =>
    ChatMessage(
      envelopeId: envelopeId ?? 'env-$senderDeviceId-${body.hashCode}',
      conversationId: _kConversationId,
      senderDeviceId: senderDeviceId,
      body: body,
      serverTs: ts ?? DateTime(2026, 1, 1, 10, 0),
      mine: mine,
      kind: MessageKind.text,
    );

ChatMessage _fileMsg({
  required MessageDeliveryStatus status,
  bool mine = true,
}) =>
    ChatMessage(
      envelopeId: 'env-file-1',
      conversationId: '1to1:me:bob',
      senderDeviceId: mine ? 'dev-me' : 'dev-bob',
      body: '',
      serverTs: DateTime(2026, 1, 1, 10, 0),
      mine: mine,
      kind: MessageKind.file,
      deliveryStatus: status,
      mediaFilename: 'report.pdf',
      mediaSize: 2048,
      mediaMime: 'application/pdf',
    );

Conversation _groupConv({
  String groupName = 'Atlas',
  List<GroupMember> members = const [],
  List<ChatMessage> messages = const [],
}) =>
    Conversation(
      id: _kConversationId,
      peerUsername: '',
      peerAccountId: '',
      peerDeviceId: '',
      peerIdentityPubKey: const [],
      messages: messages,
      unreadCount: 0,
      kind: ConversationKind.group,
      groupName: groupName,
      members: members,
    );

Conversation _oneToOneConv({
  List<ChatMessage> messages = const [],
  bool pending = false,
  bool hasMoreOlderMessages = false,
}) =>
    Conversation(
      id: '1to1:me:bob',
      peerUsername: '@bob',
      peerAccountId: 'acct-bob',
      peerDeviceId: 'dev-bob',
      peerIdentityPubKey: const [],
      messages: messages,
      unreadCount: 0,
      kind: ConversationKind.oneToOne,
      pending: pending,
      hasMoreOlderMessages: hasMoreOlderMessages,
    );

Widget _buildHarness(Conversation conv, {_FakeNotifier? notifier}) {
  final fake = notifier ?? _FakeNotifier(conversation: conv);

  final router = GoRouter(
    routes: [
      GoRoute(
        path: Routes.chat,
        builder: (context, state) => ChatThreadScreen(
          conversationId: state.pathParameters['conversationId'] ?? '',
        ),
      ),
      GoRoute(
        path: Routes.groupInfo,
        builder: (context, state) => const Scaffold(body: Text('GroupInfo')),
      ),
      GoRoute(
        path: Routes.contactProfile,
        builder: (context, state) =>
            const Scaffold(body: Text('ContactProfile')),
      ),
    ],
    initialLocation: Routes.chat.replaceFirst(':conversationId', conv.id),
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
  group('ChatThreadScreen media delivery ticks', () {
    // Regression: media bubbles (image/voice/video/file) used to render NO
    // status tick — only the text bubble did — so delivery/read receipts on
    // attachments were invisible even though the model status updated.
    testWidgets('a delivered outgoing file shows the done_all tick',
        (tester) async {
      final conv = _oneToOneConv(
        messages: [_fileMsg(status: MessageDeliveryStatus.delivered)],
      );
      await tester.pumpWidget(_buildHarness(conv));
      await tester.pump();
      expect(find.byIcon(Icons.done_all), findsOneWidget);
    });

    testWidgets('a sent (not yet delivered) outgoing file shows a single check',
        (tester) async {
      final conv = _oneToOneConv(
        messages: [_fileMsg(status: MessageDeliveryStatus.sent)],
      );
      await tester.pumpWidget(_buildHarness(conv));
      await tester.pump();
      expect(find.byIcon(Icons.check), findsOneWidget);
      expect(find.byIcon(Icons.done_all), findsNothing);
    });

    testWidgets('an incoming file shows no delivery tick', (tester) async {
      final conv = _oneToOneConv(
        messages: [
          _fileMsg(status: MessageDeliveryStatus.delivered, mine: false),
        ],
      );
      await tester.pumpWidget(_buildHarness(conv));
      await tester.pump();
      expect(find.byIcon(Icons.done_all), findsNothing);
    });
  });

  group('ChatThreadScreen message requests', () {
    testWidgets('pending 1:1 shows Accept/Reject bar instead of composer',
        (tester) async {
      final conv = _oneToOneConv(pending: true);
      final fake = _FakeNotifier(conversation: conv);

      await tester.pumpWidget(_buildHarness(conv, notifier: fake));
      await tester.pump();

      expect(find.byType(ChatComposer), findsNothing);
      expect(find.text('@bob wants to message you'), findsOneWidget);
      expect(find.text('Accept'), findsOneWidget);
      expect(find.text('Reject'), findsOneWidget);

      await tester.tap(find.text('Accept'));
      await tester.pump();
      expect(fake.acceptedRequests, equals(['1to1:me:bob']));
    });

    testWidgets('pending 1:1 offers a Report option next to Accept/Reject',
        (tester) async {
      final conv = _oneToOneConv(pending: true);

      await tester.pumpWidget(_buildHarness(conv));
      await tester.pump();

      expect(find.text('Report'), findsOneWidget);
    });

    Future<_FakeNotifier> reportFromRequestBar(
      WidgetTester tester, {
      bool fail = false,
    }) async {
      final conv = _oneToOneConv(pending: true);
      final fake = _FakeNotifier(conversation: conv)..reportFails = fail;
      await tester.pumpWidget(_buildHarness(conv, notifier: fake));
      await tester.pump();
      await tester.tap(find.text('Report'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Spam'));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('report-submit')));
      await tester.pumpAndSettle();
      return fake;
    }

    testWidgets('Report from a message request submits the chosen reason',
        (tester) async {
      final fake = await reportFromRequestBar(tester);

      expect(fake.reports.single.reason, ReportReason.spam);
    });

    testWidgets('Report from a message request also rejects it',
        (tester) async {
      final fake = await reportFromRequestBar(tester);

      expect(fake.rejectedRequests, equals(['1to1:me:bob']));
    });

    testWidgets('reporting a request does not ask to block separately',
        (tester) async {
      final conv = _oneToOneConv(pending: true);
      await tester.pumpWidget(_buildHarness(conv));
      await tester.pump();

      await tester.tap(find.text('Report'));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('report-also-block')), findsNothing);
    });

    testWidgets('a failed report leaves the request pending (not rejected)',
        (tester) async {
      final fake = await reportFromRequestBar(tester, fail: true);

      expect(fake.rejectedRequests, isEmpty);
    });

    testWidgets('non-pending 1:1 shows the composer, no request bar',
        (tester) async {
      final conv = _oneToOneConv();

      await tester.pumpWidget(_buildHarness(conv));
      await tester.pump();

      expect(find.byType(ChatComposer), findsOneWidget);
      expect(find.text('Accept'), findsNothing);
      expect(find.text('Reject'), findsNothing);
    });
  });

  group('ChatThreadScreen', () {
    testWidgets(
        'group thread renders SystemLine for kind=system messages',
        (tester) async {
      final systemBody = SystemEvent.memberJoined(
        accountId: 'acct-lin',
        username: '@lin',
        epoch: 2,
      ).toJsonString();

      final conv = _groupConv(
        members: [_member(username: '@lin', deviceId: 'dev-lin')],
        messages: [_systemMsg(body: systemBody)],
      );

      await tester.pumpWidget(_buildHarness(conv));
      await tester.pump();

      expect(find.byType(SystemLine), findsOneWidget);
      expect(find.textContaining('joined the group'), findsOneWidget);
    });

    testWidgets(
        'group thread shows sender label above non-self bubble',
        (tester) async {
      final conv = _groupConv(
        members: [_member(username: '@lin', deviceId: 'dev-lin')],
        messages: [
          _textMsg(senderDeviceId: 'dev-lin', body: 'hello'),
        ],
      );

      await tester.pumpWidget(_buildHarness(conv));
      await tester.pump();

      expect(find.text('@lin'), findsOneWidget);
    });

    testWidgets(
        'group thread suppresses label on consecutive same-sender bubbles',
        (tester) async {
      final ts = DateTime(2026, 1, 1, 10, 0);
      final conv = _groupConv(
        members: [_member(username: '@ada', deviceId: 'dev-ada')],
        messages: [
          _textMsg(
            senderDeviceId: 'dev-ada',
            body: 'msg 1',
            envelopeId: 'env-1',
            ts: ts,
          ),
          _textMsg(
            senderDeviceId: 'dev-ada',
            body: 'msg 2',
            envelopeId: 'env-2',
            ts: ts.add(const Duration(minutes: 1)),
          ),
          _textMsg(
            senderDeviceId: 'dev-ada',
            body: 'msg 3',
            envelopeId: 'env-3',
            ts: ts.add(const Duration(minutes: 2)),
          ),
        ],
      );

      await tester.pumpWidget(_buildHarness(conv));
      await tester.pump();

      // Label appears only once — at the first message of the run.
      expect(find.text('@ada'), findsOneWidget);
    });

    testWidgets(
        'load-older spinner sits at the top (oldest end), above all messages',
        (tester) async {
      // Regression: the sentinel was appended to a list rendered via
      // `widgets.reversed` into a `reverse: true` ListView, which pinned it to
      // the BOTTOM (below the newest message) where the prefetch never fires —
      // an endless spinner under the latest bubble. It must render at the top.
      final conv = _oneToOneConv(
        hasMoreOlderMessages: true,
        messages: [
          _textMsg(
            senderDeviceId: 'dev-bob',
            body: 'older message',
            envelopeId: 'env-old',
            ts: DateTime(2026, 1, 1, 10, 0),
          ),
          _textMsg(
            senderDeviceId: 'dev-bob',
            body: 'newer message',
            envelopeId: 'env-new',
            ts: DateTime(2026, 1, 1, 10, 5),
          ),
        ],
      );

      await tester.pumpWidget(_buildHarness(conv));
      await tester.pump();

      final spinnerY =
          tester.getCenter(find.byType(CircularProgressIndicator)).dy;
      final olderY = tester.getCenter(find.text('older message')).dy;
      final newerY = tester.getCenter(find.text('newer message')).dy;

      // reverse:true → newest at the bottom (largest dy). The "load older" cue
      // must sit above EVERY message (smallest dy), not under the newest one.
      expect(spinnerY, lessThan(olderY));
      expect(olderY, lessThan(newerY));
    });

    testWidgets(
        '1:1 thread does not show sender labels',
        (tester) async {
      // In a 1:1 thread, senderLabel is always null (isGroup=false). If the
      // screen incorrectly passed a label, it would fall back to the
      // senderDeviceId 'dev-bob' since members is empty. We assert that
      // 'dev-bob' never appears as rendered text.
      final conv = _oneToOneConv(
        messages: [
          _textMsg(
            senderDeviceId: 'dev-bob',
            body: 'hello from bob',
          ),
        ],
      );

      await tester.pumpWidget(_buildHarness(conv));
      await tester.pump();

      expect(find.text('dev-bob'), findsNothing);
    });

    testWidgets(
        'composer is replaced with read-only banner when user was removed from group',
        (tester) async {
      // Empty members list = user was removed (Task 12 clears members on self-removed).
      final conv = _groupConv(members: const [], messages: const []);

      await tester.pumpWidget(_buildHarness(conv));
      await tester.pump();

      expect(find.text('You were removed from this group'), findsOneWidget);
      expect(find.byType(ChatComposer), findsNothing);
    });

    testWidgets(
        'group thread top bar shows "{groupName} · {N} members"',
        (tester) async {
      final conv = _groupConv(
        groupName: 'Atlas',
        members: [
          _member(username: '@a', deviceId: 'dev-a', isSelf: true),
          _member(username: '@b', deviceId: 'dev-b'),
          _member(username: '@c', deviceId: 'dev-c'),
        ],
        messages: const [],
      );

      await tester.pumpWidget(_buildHarness(conv));
      await tester.pump();

      expect(find.textContaining('Atlas'), findsOneWidget);
      expect(find.textContaining('3 members'), findsOneWidget);
    });
  });

  group('ChatThreadScreen null-conversation state', () {
    // A thread can be deep-linked (e.g. from a notification tap) before the
    // notifier has hydrated from disk, so byId is transiently null. During that
    // window we want a loader, not the misleading "no such conversation" text.
    Widget nullConvHarness(_FakeNotifier fake) {
      final router = GoRouter(
        routes: [
          GoRoute(
            path: Routes.chat,
            builder: (context, state) => ChatThreadScreen(
              conversationId: state.pathParameters['conversationId'] ?? '',
            ),
          ),
        ],
        initialLocation: Routes.chat.replaceFirst(':conversationId', 'absent'),
      );
      return ProviderScope(
        overrides: [conversationsProvider.overrideWith((ref) => fake)],
        child: MaterialApp.router(
          theme: buildLightTheme(),
          routerConfig: router,
        ),
      );
    }

    testWidgets('shows a loader (not the empty message) before hydration',
        (tester) async {
      final fake = _FakeNotifier(
        conversation: null,
        hydrated: false,
        connectionState: conn.ConnectionState.connecting,
      );

      await tester.pumpWidget(nullConvHarness(fake));
      await tester.pump();

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.textContaining('has not started yet'), findsNothing);
    });

    testWidgets('shows a loader while connecting even once hydrated',
        (tester) async {
      final fake = _FakeNotifier(
        conversation: null,
        hydrated: true,
        connectionState: conn.ConnectionState.reconnecting,
      );

      await tester.pumpWidget(nullConvHarness(fake));
      await tester.pump();

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.textContaining('has not started yet'), findsNothing);
    });

    testWidgets(
        'shows a loader when connected but the first catchup has not settled',
        (tester) async {
      // The gap a notification tap to a brand-new conversation hits: hydrated
      // and online, but the pushed conversation has not been delivered by
      // catchup yet, so byId is still null for a perfectly valid thread.
      final fake = _FakeNotifier(
        conversation: null,
        hydrated: true,
        connectionState: conn.ConnectionState.connected,
        catchupSettled: false,
      );

      await tester.pumpWidget(nullConvHarness(fake));
      await tester.pump();

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.textContaining('has not started yet'), findsNothing);
    });

    testWidgets(
        'falls back to the empty message once hydrated, online, and caught up',
        (tester) async {
      final fake = _FakeNotifier(
        conversation: null,
        hydrated: true,
        connectionState: conn.ConnectionState.connected,
        catchupSettled: true,
      );

      await tester.pumpWidget(nullConvHarness(fake));
      await tester.pump();

      expect(find.textContaining('has not started yet'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets(
        'deep-linked thread drives connect() so a fresh notifier hydrates',
        (tester) async {
      // Regression: a thread reached by a notification tap is a top-level route
      // with the chat list (the usual connect() driver) NOT mounted. If the
      // notifier is fresh/un-hydrated — e.g. just rebuilt by a built-in-Tor
      // restart on resume — nothing would connect it and the loader spins
      // forever. The thread must connect it itself.
      final fake = _FakeNotifier(
        conversation: null,
        hydrated: false,
        connectionState: conn.ConnectionState.connecting,
      );

      await tester.pumpWidget(nullConvHarness(fake));
      await tester.pump(); // let the post-build microtask run

      expect(fake.connectCalls, 1);
    });

    testWidgets(
        'connect() is driven once per instance, not on every rebuild',
        (tester) async {
      final fake = _FakeNotifier(
        conversation: null,
        hydrated: false,
        connectionState: conn.ConnectionState.connecting,
      );

      await tester.pumpWidget(nullConvHarness(fake));
      await tester.pump();
      expect(fake.connectCalls, 1);

      // A rebuild of the SAME instance (e.g. a connection-state pulse) must not
      // re-drive connect() — the identical-instance guard holds.
      fake.notifyListeners();
      await tester.pump();
      expect(fake.connectCalls, 1);
    });

    testWidgets('the loader names the reconnect while the socket is down',
        (tester) async {
      final fake = _FakeNotifier(
        conversation: null,
        hydrated: true,
        connectionState: conn.ConnectionState.reconnecting,
      );

      await tester.pumpWidget(nullConvHarness(fake));
      await tester.pump();

      // A proper message, not a bare spinner. (Tor is off in this harness, so
      // it's the plain wording, not "over Tor".)
      expect(find.textContaining('Reconnecting'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('the loader says "loading" once connected but not caught up',
        (tester) async {
      final fake = _FakeNotifier(
        conversation: null,
        hydrated: true,
        connectionState: conn.ConnectionState.connected,
        catchupSettled: false,
      );

      await tester.pumpWidget(nullConvHarness(fake));
      await tester.pump();

      expect(find.textContaining('Loading conversation'), findsOneWidget);
    });
  });
}
