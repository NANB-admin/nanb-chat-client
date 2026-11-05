import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/app/design_tokens.dart';
import 'package:nanb_chat/app/theme.dart';
import 'package:nanb_chat/features/chat/conversations_notifier.dart';
import 'package:nanb_chat/features/chat/models/chat_message.dart';
import 'package:nanb_chat/features/chat/models/conversation.dart';
import 'package:nanb_chat/features/chat/models/group_member.dart';
import 'package:nanb_chat/features/chat/models/message_kind.dart';
import 'package:nanb_chat/features/chat/widgets/chat_atoms.dart';
import 'package:nanb_chat/features/chat/widgets/message_bubble.dart';
import 'package:nanb_chat/features/chat/widgets/sender_name_label.dart';
import 'package:nanb_chat/features/chat/widgets/thread_messages_list.dart';
import 'package:nanb_chat/features/chat/widgets/typing_bubble.dart';

// Rendering plain text bubbles never calls back into the notifier, so a
// noSuchMethod stub is all the list needs to build.
class _NoopNotifier extends ChangeNotifier implements ConversationsNotifier {
  // The long-press menu reads these.
  @override
  Conversation? byId(String id) => null;

  @override
  String get myAccountId => '';

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

ChatMessage _textMsg({
  required String body,
  required DateTime ts,
  String envelopeId = '',
}) =>
    ChatMessage(
      envelopeId: envelopeId.isEmpty ? 'env-${body.hashCode}' : envelopeId,
      conversationId: '1to1:me:bob',
      senderDeviceId: 'dev-bob',
      body: body,
      serverTs: ts,
      mine: false,
      kind: MessageKind.text,
    );

Widget _host(
  List<ChatMessage> messages, {
  ValueChanged<String>? onJumpToMessageId,
  bool peerTyping = false,
  ValueChanged<ChatMessage>? onEdit,
}) =>
    MaterialApp(
      theme: buildLightTheme(),
      home: Scaffold(
        body: MessagesList(
          messages: messages,
          hasMoreOlderMessages: false,
          scrollController: ScrollController(),
          t: DesignTokens.light,
          notifier: _NoopNotifier(),
          isGroup: false,
          members: const <GroupMember>[],
          onReply: (_) {},
          messageKeys: <String, GlobalKey>{},
          onJumpToMessageId: onJumpToMessageId,
          peerTyping: peerTyping,
          onEdit: onEdit,
        ),
      ),
    );

GroupMember _groupMember(String name) => GroupMember(
      accountId: 'acct-$name',
      username: '@$name',
      deviceId: 'dev-$name',
      identityPubKey: const [1],
      x25519PubKey: const [2],
      isAdmin: false,
      isSelf: false,
    );

ChatMessage _groupMsg(String from, String body, int minute) => ChatMessage(
      envelopeId: 'env-$from-$minute',
      conversationId: 'group:g',
      senderDeviceId: 'dev-$from',
      body: body,
      serverTs: DateTime(2026, 1, 1, 10, minute),
      mine: false,
      kind: MessageKind.text,
    );

Widget _groupHost(List<ChatMessage> messages) => MaterialApp(
      theme: buildLightTheme(),
      home: Scaffold(
        body: MessagesList(
          messages: messages,
          hasMoreOlderMessages: false,
          scrollController: ScrollController(),
          t: DesignTokens.light,
          notifier: _NoopNotifier(),
          isGroup: true,
          members: [_groupMember('ada'), _groupMember('bob')],
          onReply: (_) {},
          messageKeys: <String, GlobalKey>{},
        ),
      ),
    );

ChatMessage _replyMsg({required String replyTo}) => ChatMessage(
      envelopeId: 'env-reply',
      conversationId: '1to1:me:bob',
      senderDeviceId: 'dev-bob',
      body: 'my answer',
      serverTs: DateTime(2026, 1, 1, 10, 5),
      mine: false,
      kind: MessageKind.text,
      replyToEnvelopeId: replyTo,
      replyToSender: '@ada',
      replyToPreview: 'the original question',
    );

ChatMessage _ownMsg({bool edited = false}) => ChatMessage(
      envelopeId: 'env-own',
      conversationId: '1to1:me:bob',
      senderDeviceId: 'dev-me',
      body: 'my words',
      serverTs: DateTime.now().toUtc().subtract(const Duration(minutes: 1)),
      mine: true,
      kind: MessageKind.text,
      edited: edited,
    );

void main() {
  group('MessagesList group sender names', () {
    testWidgets('each sender in a group is named on their bubble',
        (tester) async {
      await tester.pumpWidget(_groupHost([
        _groupMsg('ada', 'hi', 1),
        _groupMsg('bob', 'hello', 2),
      ]));
      await tester.pump();

      expect(find.byType(SenderNameLabel), findsNWidgets(2));
    });

    testWidgets('different senders are drawn in different colors',
        (tester) async {
      await tester.pumpWidget(_groupHost([
        _groupMsg('ada', 'hi', 1),
        _groupMsg('bob', 'hello', 2),
      ]));
      await tester.pump();

      final colors = tester
          .widgetList<SenderNameLabel>(find.byType(SenderNameLabel))
          .map((l) => l.color)
          .toSet();

      expect(colors.length, 2);
    });

    testWidgets('a sender keeps one color across separated runs',
        (tester) async {
      await tester.pumpWidget(_groupHost([
        _groupMsg('ada', 'one', 1),
        _groupMsg('bob', 'two', 2),
        _groupMsg('ada', 'three', 3),
      ]));
      await tester.pump();

      final adaColors = tester
          .widgetList<SenderNameLabel>(find.byType(SenderNameLabel))
          .where((l) => l.label == '@ada')
          .map((l) => l.color)
          .toSet();

      expect(adaColors, hasLength(1));
    });

    testWidgets('consecutive messages from one sender are named only once',
        (tester) async {
      await tester.pumpWidget(_groupHost([
        _groupMsg('ada', 'one', 1),
        _groupMsg('ada', 'two', 2),
      ]));
      await tester.pump();

      expect(find.byType(SenderNameLabel), findsOneWidget);
    });

    testWidgets('a 1:1 thread shows no sender names', (tester) async {
      await tester.pumpWidget(_host([
        _textMsg(body: 'hi', ts: DateTime(2026, 1, 1, 10, 0)),
      ]));
      await tester.pump();

      expect(find.byType(SenderNameLabel), findsNothing);
    });
  });

  group('MessagesList editing', () {
    testWidgets('offers Edit on my recent text message', (tester) async {
      await tester.pumpWidget(_host([_ownMsg()], onEdit: (_) {}));
      await tester.pump();

      await tester.longPress(find.text('my words'));
      await tester.pumpAndSettle();

      expect(find.text('Edit'), findsOneWidget);
    });

    testWidgets('picking Edit reports the message', (tester) async {
      ChatMessage? edited;
      await tester.pumpWidget(_host([_ownMsg()], onEdit: (m) => edited = m));
      await tester.pump();

      await tester.longPress(find.text('my words'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Edit'));

      expect(edited?.envelopeId, 'env-own');
    });

    testWidgets('offers no Edit on a message from the peer', (tester) async {
      final theirs = _textMsg(body: 'their words', ts: DateTime.now());
      await tester.pumpWidget(_host([theirs], onEdit: (_) {}));
      await tester.pump();

      await tester.longPress(find.text('their words'));
      await tester.pumpAndSettle();

      expect(find.text('Edit'), findsNothing);
    });

    testWidgets('offers no Edit when editing is disabled', (tester) async {
      await tester.pumpWidget(_host([_ownMsg()]));
      await tester.pump();

      await tester.longPress(find.text('my words'));
      await tester.pumpAndSettle();

      expect(find.text('Edit'), findsNothing);
    });

    testWidgets('labels an edited message', (tester) async {
      await tester.pumpWidget(_host([_ownMsg(edited: true)]));
      await tester.pump();

      expect(find.textContaining('edited'), findsOneWidget);
    });

    testWidgets('does not label an unedited message', (tester) async {
      await tester.pumpWidget(_host([_ownMsg()]));
      await tester.pump();

      expect(find.textContaining('edited'), findsNothing);
    });
  });

  group('MessagesList typing bubble', () {
    final messages = [_textMsg(body: 'hello', ts: DateTime(2026, 1, 1, 10, 0))];

    testWidgets('shows a typing bubble while the peer is typing',
        (tester) async {
      await tester.pumpWidget(_host(messages, peerTyping: true));
      await tester.pump();

      expect(find.byType(TypingBubble), findsOneWidget);
    });

    testWidgets('shows no typing bubble otherwise', (tester) async {
      await tester.pumpWidget(_host(messages));
      await tester.pump();

      expect(find.byType(TypingBubble), findsNothing);
    });

    testWidgets('keeps the messages visible while the peer types',
        (tester) async {
      await tester.pumpWidget(_host(messages, peerTyping: true));
      await tester.pump();

      expect(find.text('hello'), findsOneWidget);
    });
  });

  group('MessagesList virtualization (FIX #3)', () {
    testWidgets(
        'builds only the on-screen bubbles, not one widget per loaded message',
        (tester) async {
      final base = DateTime(2026, 1, 1, 10, 0);
      // A large loaded window — the kind pagination grows to. The old
      // `ListView(children: …)` built a bubble for every one of these on every
      // rebuild; the builder must instead cap work to the viewport.
      final messages = List<ChatMessage>.generate(
        400,
        (i) => _textMsg(
          body: 'message $i',
          ts: base.add(Duration(minutes: i)),
          envelopeId: 'env-$i',
        ),
      );

      await tester.pumpWidget(_host(messages));
      await tester.pump();

      final built = tester.widgetList<MessageBubble>(find.byType(MessageBubble));
      expect(built, isNotEmpty);
      // Viewport (600px) + cache extent holds only a few dozen rows, far fewer
      // than the 400 loaded — proof the list is lazily virtualized.
      expect(built.length, lessThan(120));
    });

    testWidgets('renders a day separator for each calendar day', (tester) async {
      final messages = [
        _textMsg(body: 'monday', ts: DateTime(2026, 1, 1, 10, 0)),
        _textMsg(body: 'tuesday', ts: DateTime(2026, 1, 2, 10, 0)),
      ];

      await tester.pumpWidget(_host(messages));
      await tester.pump();

      expect(find.byType(DaySeparator), findsNWidgets(2));
    });

    testWidgets('keeps newest-at-bottom ordering (reverse) after refactor',
        (tester) async {
      final messages = [
        _textMsg(body: 'older', ts: DateTime(2026, 1, 1, 10, 0)),
        _textMsg(body: 'newer', ts: DateTime(2026, 1, 1, 10, 5)),
      ];

      await tester.pumpWidget(_host(messages));
      await tester.pump();

      final olderY = tester.getCenter(find.text('older')).dy;
      final newerY = tester.getCenter(find.text('newer')).dy;
      expect(olderY, lessThan(newerY));
    });
  });

  group('MessagesList reply jump', () {
    testWidgets('tapping a reply preview jumps to the replied-to envelope',
        (tester) async {
      final jumps = <String>[];
      await tester.pumpWidget(_host([_replyMsg(replyTo: 'env-original')],
          onJumpToMessageId: jumps.add));
      await tester.pump();

      await tester.tap(find.text('the original question'));

      expect(jumps, ['env-original']);
    });

    testWidgets('a reply preview does nothing when jumping is disabled',
        (tester) async {
      await tester.pumpWidget(_host([_replyMsg(replyTo: 'env-original')]));
      await tester.pump();

      await tester.tap(find.text('the original question'));

      expect(find.text('the original question'), findsOneWidget);
    });
  });
}
