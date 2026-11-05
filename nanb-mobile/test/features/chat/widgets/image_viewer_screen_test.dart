import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/features/chat/widgets/image_viewer_screen.dart';

final Uint8List _onePxPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR42mNk+M9Q'
  'DwADhgGAWjR9awAAAABJRU5ErkJggg==',
);

Widget _host() => MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => ImageViewerScreen.open(context, _onePxPng),
            child: const Text('open'),
          ),
        ),
      ),
    );

void main() {
  testWidgets('opening shows the image', (tester) async {
    await tester.pumpWidget(_host());

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.byType(Image), findsOneWidget);
  });

  testWidgets('the image can be zoomed', (tester) async {
    await tester.pumpWidget(_host());

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.byType(InteractiveViewer), findsOneWidget);
  });

  testWidgets('the viewer fills the whole screen, not just the close button', (tester) async {
    await tester.pumpWidget(_host());

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(
      tester.getSize(find.byType(InteractiveViewer)),
      tester.view.physicalSize / tester.view.devicePixelRatio,
    );
  });

  testWidgets('the close button returns to the previous screen', (tester) async {
    await tester.pumpWidget(_host());
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();

    expect(find.byType(ImageViewerScreen), findsNothing);
  });
}
