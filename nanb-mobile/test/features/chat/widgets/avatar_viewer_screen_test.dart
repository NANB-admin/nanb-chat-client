import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/features/chat/widgets/avatar_viewer_screen.dart';

final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR42mNk+M9Q'
  'DwADhgGAWjR9awAAAABJRU5ErkJggg==',
);

Widget _host() => MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => AvatarViewerScreen.open(context, _png),
            child: const Text('open'),
          ),
        ),
      ),
    );

Future<void> _openViewer(WidgetTester tester) async {
  await tester.pumpWidget(_host());
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('opening shows the enlarged photo', (tester) async {
    await _openViewer(tester);

    expect(find.byType(Image), findsOneWidget);
  });

  testWidgets('the enlarged photo is bigger than a header avatar',
      (tester) async {
    await _openViewer(tester);

    expect(tester.getSize(find.byType(Image)).width, greaterThan(160));
  });

  testWidgets('tapping the photo closes the viewer', (tester) async {
    await _openViewer(tester);

    await tester.tap(find.byType(Image));
    await tester.pumpAndSettle();

    expect(find.byType(AvatarViewerScreen), findsNothing);
  });

  testWidgets('the viewer offers no save, copy or share action',
      (tester) async {
    await _openViewer(tester);

    expect(find.byType(IconButton), findsNothing);
  });
}
