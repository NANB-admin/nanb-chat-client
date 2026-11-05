import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/features/chat/widgets/typing_bubble.dart';

void main() {
  testWidgets('shows three dots', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: TypingBubble())),
    );

    final dots = find.descendant(
      of: find.byType(TypingBubble),
      matching: find.byWidgetPredicate(
        (w) =>
            w is Container &&
            w.decoration is BoxDecoration &&
            (w.decoration! as BoxDecoration).shape == BoxShape.circle,
      ),
    );
    expect(dots, findsNWidgets(3));
  });

  testWidgets('animates without throwing', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: TypingBubble())),
    );

    await tester.pump(const Duration(milliseconds: 600));

    expect(tester.takeException(), isNull);
  });
}
