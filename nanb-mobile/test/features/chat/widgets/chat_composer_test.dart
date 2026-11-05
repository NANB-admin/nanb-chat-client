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
}
