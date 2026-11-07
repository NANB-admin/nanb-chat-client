import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/app/theme.dart';
import 'package:nanb_chat/features/chat/models/chat_message.dart';
import 'package:nanb_chat/features/chat/models/message_kind.dart';
import 'package:nanb_chat/features/chat/widgets/view_once_bubble.dart';

ChatMessage _msg(
        {MessageKind kind = MessageKind.image,
        DateTime? openedAt,
        bool mine = false,
        bool failed = false}) =>
    ChatMessage(
      envelopeId: 'env-1',
      conversationId: '1to1:a:b',
      senderDeviceId: 'dev-b',
      body: 'never shown',
      serverTs: DateTime.utc(2026, 11, 7, 10),
      mine: mine,
      failed: failed,
      kind: kind,
      viewOnce: true,
      viewOnceOpenedAt: openedAt,
    );

Widget _host(ChatMessage m, {VoidCallback? onOpen}) => MaterialApp(
      theme: buildLightTheme(),
      home: Scaffold(body: ViewOnceBubble(message: m, time: '10:00', onOpen: onOpen)),
    );

void main() {
  testWidgets('an unopened photo says what it is, not what it shows',
      (tester) async {
    await tester.pumpWidget(_host(_msg()));

    expect(find.text('Photo · View once'), findsOneWidget);
    expect(find.text('never shown'), findsNothing);
  });

  testWidgets('an opened one says Opened', (tester) async {
    await tester.pumpWidget(_host(_msg(openedAt: DateTime.utc(2026))));

    expect(find.text('Opened'), findsOneWidget);
  });

  testWidgets('tapping it opens it', (tester) async {
    var opened = 0;
    await tester.pumpWidget(_host(_msg(), onOpen: () => opened++));

    await tester.tap(find.byType(ViewOnceBubble));

    expect(opened, 1);
  });

  test('a text message is labelled as a message', () {
    expect(ViewOnceBubble.label(_msg(kind: MessageKind.text)),
        'Message · View once');
  });

  testWidgets('a view-once message that failed to send says so below it',
      (tester) async {
    await tester.pumpWidget(_host(_msg(mine: true, failed: true)));

    expect(find.text('Photo · View once'), findsOneWidget);
    expect(find.text('Not sent · Tap to retry'), findsOneWidget);
  });
}
