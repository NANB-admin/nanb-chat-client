import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/features/chat/widgets/media_caption_screen.dart';

final _imageBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR42mNk+M9Q'
  'DwADhgGAWjR9awAAAABJRU5ErkJggg==',
);

Future<void> _openPreview(
  WidgetTester tester, {
  String initialCaption = '',
  required ValueChanged<String?> onResult,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async {
              final caption = await Navigator.of(context).push<String>(
                MaterialPageRoute(
                  builder: (_) => MediaCaptionScreen(
                    bytes: _imageBytes,
                    initialCaption: initialCaption,
                  ),
                ),
              );
              onResult(caption);
            },
            child: const Text('Select image'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Select image'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('selecting media waits for explicit confirmation', (
    tester,
  ) async {
    var completed = false;
    await _openPreview(tester, onResult: (_) => completed = true);

    expect(find.byType(Image), findsOneWidget);
    expect(completed, isFalse);
  });

  testWidgets('prefills the caption with the existing draft', (tester) async {
    await _openPreview(tester, initialCaption: 'My draft', onResult: (_) {});

    expect(find.text('My draft'), findsOneWidget);
  });

  testWidgets('Send returns the edited multiline caption', (tester) async {
    String? result;
    await _openPreview(tester, onResult: (caption) => result = caption);
    await tester.enterText(
      find.byType(TextField),
      '  First line\nSecond line  ',
    );
    await tester.tap(find.byTooltip('Send'));
    await tester.pumpAndSettle();

    expect(result, 'First line\nSecond line');
  });

  testWidgets('Send allows media without a caption', (tester) async {
    String? result;
    await _openPreview(tester, onResult: (caption) => result = caption);
    await tester.tap(find.byTooltip('Send'));
    await tester.pumpAndSettle();

    expect(result, '');
  });

  testWidgets('Cancel discards the selection', (tester) async {
    String? result = 'not cancelled';
    await _openPreview(tester, onResult: (caption) => result = caption);
    await tester.enterText(find.byType(TextField), 'Do not send');
    await tester.tap(find.byTooltip('Cancel'));
    await tester.pumpAndSettle();

    expect(result, isNull);
  });

  testWidgets('system back discards the selection', (tester) async {
    String? result = 'not cancelled';
    await _openPreview(tester, onResult: (caption) => result = caption);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(result, isNull);
  });

  testWidgets('caption and Send remain visible above the keyboard', (
    tester,
  ) async {
    await _openPreview(tester, onResult: (_) {});
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    addTearDown(tester.view.resetViewInsets);
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();

    final keyboardTop =
        tester.view.physicalSize.height / tester.view.devicePixelRatio -
        300 / tester.view.devicePixelRatio;
    expect(
      tester.getBottomRight(find.byType(TextField)).dy,
      lessThanOrEqualTo(keyboardTop),
    );
    expect(
      tester.getBottomRight(find.byTooltip('Send')).dy,
      lessThanOrEqualTo(keyboardTop),
    );
    expect(tester.takeException(), isNull);
  });
}
