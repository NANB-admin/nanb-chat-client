import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/app/providers.dart';
import 'package:nanb_chat/app/theme.dart';
import 'package:nanb_chat/core/crypto/crypto_bridge.dart';
import 'package:nanb_chat/features/chat/avatar_loader.dart';
import 'package:nanb_chat/features/chat/contact_profile_screen.dart';
import 'package:nanb_chat/features/chat/conversations_notifier.dart';
import 'package:nanb_chat/features/chat/media_pipeline.dart';
import 'package:nanb_chat/features/chat/models/conversation.dart';
import 'package:nanb_chat/features/chat/models/message_kind.dart';
import 'package:nanb_chat/features/chat/widgets/avatar_image.dart';

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

class _MuteCall {
  const _MuteCall(this.conversationId, this.muted);
  final String conversationId;
  final bool muted;
}

class _FakeNotifier extends ChangeNotifier implements ConversationsNotifier {
  _FakeNotifier(this._convo, {this.avatar});
  final Conversation _convo;
  final MediaDescriptor? avatar;

  final List<_MuteCall> muteCalls = [];
  final List<String> clearCalls = [];

  @override
  Conversation? byId(String id) => id == _convo.id ? _convo : null;

  @override
  List<Conversation> get conversations => [_convo];

  @override
  MediaDescriptor? peerAvatarDescriptor(Conversation c) => avatar;

  @override
  Future<void> refreshPeerProfile(String conversationId) async {}

  @override
  Future<void> setMuted(String conversationId, bool muted) async {
    muteCalls.add(_MuteCall(conversationId, muted));
  }

  @override
  Future<void> clearMessages(String conversationId) async {
    clearCalls.add(conversationId);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeCrypto implements CryptoBridge {
  @override
  Future<Set<String>> groupMemberDeviceIds(String groupId) async => const {};

  @override
  Future<bool> consumeMlsStoreReset() async => false;

  @override
  Future<IdentityHandle?> currentIdentity() async => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Never hits the network — AvatarImage's load fails gracefully to initials,
/// so the test stays hermetic (no Dio, no pending timers).
class _FakeMediaPipeline implements MediaPipeline {
  @override
  Future<List<int>> download(MediaDescriptor descriptor) async =>
      throw UnimplementedError();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

const _convoId = '1to1:a:b';

Conversation _convo({
  bool muted = false,
  int disappearingTtl = -1,
  bool blocked = false,
}) =>
    Conversation(
      id: _convoId,
      peerUsername: '@bob',
      peerAccountId: 'acc-b',
      peerDeviceId: 'dev-b',
      peerIdentityPubKey: const [1, 2, 3],
      peerX25519PubKey: const [4, 5, 6],
      messages: const [],
      unreadCount: 0,
      verified: true,
      muted: muted,
      disappearingTtl: disappearingTtl,
      blocked: blocked,
    );

const _descriptor = MediaDescriptor(
  kind: MessageKind.image,
  mediaId: 'avatar-1',
  key: [1, 2, 3],
  sha256: [4, 5, 6],
  sizeBytes: 10,
  mimeType: 'image/jpeg',
);

Widget _harness(_FakeNotifier fake) => ProviderScope(
      overrides: [
        conversationsProvider.overrideWith((ref) => fake),
        cryptoBridgeProvider.overrideWithValue(_FakeCrypto()),
        avatarLoaderProvider.overrideWithValue(AvatarLoader(_FakeMediaPipeline())),
      ],
      child: MaterialApp(
        theme: buildLightTheme(),
        home: const ContactProfileScreen(conversationId: _convoId),
      ),
    );

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// The profile body is a (lazy) ListView and the safety-number section is tall
/// (a 12-group grid), so the rows below it (disappearing / notifications /
/// block) fall outside the default 600px test viewport and never build. Lay the
/// test out on a tall surface so the whole screen is built + findable.
void _useTallSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

void main() {
  testWidgets('renders the peer avatar via AvatarImage with the descriptor',
      (tester) async {
    final fake = _FakeNotifier(_convo(), avatar: _descriptor);
    await tester.pumpWidget(_harness(fake));
    await tester.pump();

    final avatar = tester.widget<AvatarImage>(find.byType(AvatarImage));
    expect(avatar.descriptor, same(_descriptor),
        reason: 'the contact header must pass the peer avatar descriptor');
  });

  testWidgets(
      'safety number unavailable: shows the not-available note + Copy disabled',
      (tester) async {
    _useTallSurface(tester);
    // _FakeCrypto returns a null identity, so the safety number cannot be
    // computed — the "not available yet" state. Copy must be DISABLED (this is
    // the bug we fixed: it used to show placeholder dots with a dead button and
    // no explanation).
    final fake = _FakeNotifier(_convo(), avatar: null);
    await tester.pumpWidget(_harness(fake));
    await tester.pump(); // let _loadSafetyNumber's microtask resolve + rebuild

    expect(find.textContaining('Not available yet'), findsOneWidget);
    final copyBtn = tester.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, 'Copy'));
    expect(copyBtn.onPressed, isNull,
        reason: 'Copy is disabled when there is no number to copy');
  });

  testWidgets('disappearing row shows "Default" when not overridden',
      (tester) async {
    _useTallSurface(tester);
    final fake = _FakeNotifier(_convo(), avatar: null);
    await tester.pumpWidget(_harness(fake));
    await tester.pump();

    expect(find.text('Disappearing messages'), findsOneWidget);
    expect(find.text('Default'), findsOneWidget);
  });

  testWidgets('tapping Notifications toggles mute', (tester) async {
    _useTallSurface(tester);
    final fake = _FakeNotifier(_convo(), avatar: null);
    await tester.pumpWidget(_harness(fake));
    await tester.pump();

    expect(find.text('On'), findsOneWidget); // unmuted label
    await tester.ensureVisible(find.text('Notifications'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Notifications'));
    await tester.pump();

    expect(fake.muteCalls.single.conversationId, _convoId);
    expect(fake.muteCalls.single.muted, isTrue);
  });

  testWidgets('muted conversation shows the "Muted" label', (tester) async {
    _useTallSurface(tester);
    final fake = _FakeNotifier(_convo(muted: true), avatar: null);
    await tester.pumpWidget(_harness(fake));
    await tester.pump();

    expect(find.text('Muted'), findsOneWidget);
  });

  testWidgets('3-dot menu offers Clear chat history and Block', (tester) async {
    _useTallSurface(tester);
    final fake = _FakeNotifier(_convo(), avatar: null);
    await tester.pumpWidget(_harness(fake));
    await tester.pump();

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();

    // The menu item is unique; "Block" also appears as a settings row, so the
    // menu adds a second one.
    expect(find.text('Clear chat history'), findsOneWidget);
    expect(find.text('Block'), findsNWidgets(2));
  });
}
