import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/features/chat/widgets/full_emoji_picker.dart';
import 'package:nanb_chat/features/chat/widgets/reaction_chips.dart';

void main() {
  Widget host(void Function(String) onPick) => MaterialApp(
        home: Scaffold(body: ReactionPickerRow(onPick: onPick)),
      );

  testWidgets('tapping a quick-reaction emoji reports it to onPick',
      (tester) async {
    String? picked;
    await tester.pumpWidget(host((e) => picked = e));

    await tester.tap(find.text('👍'));
    await tester.pump();

    expect(picked, '👍');
  });

  testWidgets('shows a "+" affordance for reaching the full catalogue',
      (tester) async {
    await tester.pumpWidget(host((_) {}));

    expect(find.byIcon(Icons.add), findsOneWidget);
  });

  testWidgets('tapping "+" opens the full emoji catalogue', (tester) async {
    await tester.pumpWidget(host((_) {}));

    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();

    expect(find.byType(FullEmojiPicker), findsOneWidget);
  });

  testWidgets('picking a non-quick emoji from the catalogue reports it to onPick',
      (tester) async {
    String? picked;
    await tester.pumpWidget(host((e) => picked = e));

    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();

    // '😃' is in the catalogue's first tab but not in the quick set, so the
    // only match in the tree is the catalogue grid cell.
    await tester.tap(find.text('😃'));
    await tester.pumpAndSettle();

    expect(picked, '😃');
    // The catalogue closed itself once a choice was made.
    expect(find.byType(FullEmojiPicker), findsNothing);
  });
}
