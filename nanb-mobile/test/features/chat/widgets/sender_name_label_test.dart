import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/features/chat/widgets/sender_name_label.dart';

const _keys = ['acct-ada', 'acct-bob', 'acct-cy', 'acct-dee', 'acct-eve'];

void main() {
  test('a sender keeps the same color every time', () {
    expect(senderColorFor('acct-ada', Brightness.light),
        senderColorFor('acct-ada', Brightness.light));
  });

  test('different senders in a group get different colors', () {
    final colors = {for (final k in _keys) senderColorFor(k, Brightness.light)};

    expect(colors.length, greaterThanOrEqualTo(4));
  });

  test('the same sender is lighter in dark mode than in light mode', () {
    final light =
        HSLColor.fromColor(senderColorFor('acct-ada', Brightness.light));
    final dark =
        HSLColor.fromColor(senderColorFor('acct-ada', Brightness.dark));

    expect(dark.lightness, greaterThan(light.lightness));
  });

  test('sender colors stay dark enough to read on a light bubble', () {
    for (var i = 0; i < 40; i++) {
      expect(senderColorFor('key-$i', Brightness.light).computeLuminance(),
          lessThan(0.4),
          reason: 'key-$i');
    }
  });

  testWidgets('the label is large enough to scan', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: SenderNameLabel(label: '@ada', color: Colors.red),
      ),
    ));

    expect(tester.widget<Text>(find.text('@ada')).style!.fontSize,
        greaterThanOrEqualTo(14));
  });

  testWidgets('the label is bold', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: SenderNameLabel(label: '@ada', color: Colors.red),
      ),
    ));

    expect(tester.widget<Text>(find.text('@ada')).style!.fontWeight,
        FontWeight.w700);
  });

  testWidgets('the label uses the color it is given', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: SenderNameLabel(label: '@ada', color: Colors.teal),
      ),
    ));

    expect(tester.widget<Text>(find.text('@ada')).style!.color, Colors.teal);
  });
}
