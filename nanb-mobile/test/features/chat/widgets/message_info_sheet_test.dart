import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/features/chat/models/chat_message.dart';
import 'package:nanb_chat/features/chat/models/message_kind.dart';
import 'package:nanb_chat/features/chat/widgets/message_info_sheet.dart';

ChatMessage _msg({DateTime? deliveredAt, DateTime? readAt}) => ChatMessage(
      envelopeId: 'env-1',
      conversationId: '1to1:me:bob',
      senderDeviceId: 'dev-me',
      body: 'hi',
      serverTs: DateTime.utc(2026, 1, 1, 10, 0),
      mine: true,
      kind: MessageKind.text,
      deliveredAt: deliveredAt,
      readAt: readAt,
    );

Future<void> _pump(WidgetTester tester, ChatMessage m) => tester.pumpWidget(
      MaterialApp(home: Scaffold(body: MessageInfoSheet(message: m))),
    );

void main() {
  group('MessageInfoSheet', () {
    testWidgets('shows the sent row', (tester) async {
      await _pump(tester, _msg());

      expect(find.text('Sent'), findsOneWidget);
    });

    testWidgets('says not yet when nothing was delivered', (tester) async {
      await _pump(tester, _msg());

      expect(find.text('Not yet'), findsOneWidget);
    });

    testWidgets('explains an empty read row', (tester) async {
      await _pump(tester, _msg(deliveredAt: DateTime.utc(2026, 1, 1, 10, 1)));

      expect(find.textContaining('read receipts are off'), findsOneWidget);
    });

    testWidgets('shows the delivered and read times when known',
        (tester) async {
      await _pump(
        tester,
        _msg(
          deliveredAt: DateTime.utc(2026, 1, 1, 10, 1),
          readAt: DateTime.utc(2026, 1, 1, 10, 2),
        ),
      );

      expect(find.text('Not yet'), findsNothing);
      expect(find.textContaining('read receipts are off'), findsNothing);
    });
  });

  group('MessageInfoSheet.formatInfoTime', () {
    test('uses Today for the current day', () {
      final now = DateTime(2026, 5, 10, 18, 0);

      expect(
        MessageInfoSheet.formatInfoTime(DateTime(2026, 5, 10, 9, 5).toUtc(),
            now: now),
        'Today, 09:05',
      );
    });

    test('uses Yesterday for the day before', () {
      final now = DateTime(2026, 5, 10, 18, 0);

      expect(
        MessageInfoSheet.formatInfoTime(DateTime(2026, 5, 9, 23, 30).toUtc(),
            now: now),
        'Yesterday, 23:30',
      );
    });

    test('uses the date for older days', () {
      final now = DateTime(2026, 5, 10, 18, 0);

      expect(
        MessageInfoSheet.formatInfoTime(DateTime(2026, 3, 2, 8, 0).toUtc(),
            now: now),
        '3/2/2026, 08:00',
      );
    });
  });
}
