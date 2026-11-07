import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/features/chat/widgets/chat_composer.dart';

void main() {
  Future<TextField> pumpComposer(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatComposer(
            controller: TextEditingController(),
            onSend: () {},
          ),
        ),
      ),
    );
    return tester.widget<TextField>(find.byType(TextField));
  }

  testWidgets('the field is multiline so the keyboard shows a newline key',
      (tester) async {
    final field = await pumpComposer(tester);

    expect(field.keyboardType, TextInputType.multiline);
    expect(field.textInputAction, TextInputAction.newline);
  });

  testWidgets('the field grows with content up to a cap, then scrolls',
      (tester) async {
    final field = await pumpComposer(tester);

    expect(field.minLines, 1);
    expect(field.maxLines, greaterThan(1));
  });

  testWidgets('tapping send calls onSend when the field has text',
      (tester) async {
    var sent = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatComposer(
            controller: TextEditingController(text: 'hi'),
            onSend: () => sent++,
          ),
        ),
      ),
    );

    await tester.tap(find.byIcon(Icons.send));
    await tester.pump();

    expect(sent, 1);
  });

  testWidgets('shows a mic that calls onMic when the field is empty',
      (tester) async {
    var micced = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatComposer(
            controller: TextEditingController(),
            onSend: () {},
            onMic: () => micced++,
          ),
        ),
      ),
    );

    expect(find.byIcon(Icons.send), findsNothing);
    expect(find.byIcon(Icons.mic), findsOneWidget);

    await tester.tap(find.byIcon(Icons.mic));
    await tester.pump();

    expect(micced, 1);
  });

  group('view once', () {
    Future<void> pumpWithToggle(WidgetTester tester,
        {bool on = false, VoidCallback? onToggle}) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChatComposer(
              controller: TextEditingController(),
              onSend: () {},
              viewOnce: on,
              onToggleViewOnce: onToggle,
            ),
          ),
        ),
      );
    }

    testWidgets('the toggle is hidden without a handler', (tester) async {
      await pumpWithToggle(tester);

      expect(find.bySemanticsLabel('View once'), findsNothing);
    });

    testWidgets('tapping the toggle flips it', (tester) async {
      var flips = 0;
      await pumpWithToggle(tester, onToggle: () => flips++);

      await tester.tap(find.bySemanticsLabel('View once'));

      expect(flips, 1);
    });

    testWidgets('when on, the field says the message is view once',
        (tester) async {
      await pumpWithToggle(tester, on: true, onToggle: () {});

      expect(find.text('View once message…'), findsOneWidget);
    });
  });
}
