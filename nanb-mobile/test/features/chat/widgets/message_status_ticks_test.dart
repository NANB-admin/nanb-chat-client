import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/app/design_tokens.dart';
import 'package:nanb_chat/features/chat/models/chat_message.dart';
import 'package:nanb_chat/features/chat/widgets/message_status_ticks.dart';

void main() {
  const t = DesignTokens.dark;

  ChatMessage msg({
    bool mine = true,
    MessageDeliveryStatus status = MessageDeliveryStatus.sent,
    bool failed = false,
    bool uploading = false,
    String? outboxId,
  }) =>
      ChatMessage(
        envelopeId: 'e',
        conversationId: 'c',
        senderDeviceId: 'd',
        body: 'hi',
        serverTs: DateTime.utc(2026),
        mine: mine,
        deliveryStatus: status,
        failed: failed,
        uploading: uploading,
        outboxId: outboxId,
      );

  Future<Icon?> pumpTick(WidgetTester tester, ChatMessage m) async {
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: MessageStatusTicks(message: m, t: t))),
    );
    final icons = tester.widgetList<Icon>(find.byType(Icon));
    return icons.isEmpty ? null : icons.first;
  }

  testWidgets('renders no tick for an incoming message', (tester) async {
    expect(await pumpTick(tester, msg(mine: false)), isNull);
  });

  testWidgets('sent → single grey check', (tester) async {
    final icon = await pumpTick(tester, msg(status: MessageDeliveryStatus.sent));
    expect(icon!.icon, Icons.check);
    expect(icon.color, t.textFaint);
  });

  testWidgets('delivered → double grey check', (tester) async {
    final icon =
        await pumpTick(tester, msg(status: MessageDeliveryStatus.delivered));
    expect(icon!.icon, Icons.done_all);
    expect(icon.color, t.textFaint);
  });

  testWidgets('read → double ACCENT check (the blue ticks)', (tester) async {
    final icon = await pumpTick(tester, msg(status: MessageDeliveryStatus.read));
    expect(icon!.icon, Icons.done_all);
    expect(icon.color, t.accent);
  });

  testWidgets('failed → error mark', (tester) async {
    final icon = await pumpTick(tester, msg(failed: true));
    expect(icon!.icon, Icons.error_outline);
    expect(icon.color, t.warn);
  });

  testWidgets('a media upload in flight → clock', (tester) async {
    final icon = await pumpTick(tester, msg(uploading: true));
    expect(icon!.icon, Icons.schedule);
  });

  testWidgets('a not-yet-acked send shows an optimistic single check, even if '
      'the stored deliveryStatus is higher', (tester) async {
    final icon = await pumpTick(
        tester, msg(outboxId: 'outbox-1', status: MessageDeliveryStatus.delivered));
    expect(icon!.icon, Icons.check);
    expect(icon.color, t.textFaint);
  });
}
