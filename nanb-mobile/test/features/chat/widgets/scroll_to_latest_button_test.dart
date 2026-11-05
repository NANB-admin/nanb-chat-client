import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/features/chat/widgets/scroll_to_latest_button.dart';

Widget _host({required bool visible, required VoidCallback onPressed}) =>
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: ScrollToLatestButton(visible: visible, onPressed: onPressed),
        ),
      ),
    );

void main() {
  testWidgets('tapping the visible button reports the tap', (tester) async {
    var taps = 0;
    await tester.pumpWidget(_host(visible: true, onPressed: () => taps++));

    await tester.tap(find.byIcon(Icons.keyboard_arrow_down));

    expect(taps, 1);
  });

  testWidgets('a hidden button ignores taps', (tester) async {
    var taps = 0;
    await tester.pumpWidget(_host(visible: false, onPressed: () => taps++));

    await tester.tap(find.byIcon(Icons.keyboard_arrow_down), warnIfMissed: false);

    expect(taps, 0);
  });

  testWidgets('a hidden button is fully transparent', (tester) async {
    await tester.pumpWidget(_host(visible: false, onPressed: () {}));

    final opacity = tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity));

    expect(opacity.opacity, 0);
  });
}
