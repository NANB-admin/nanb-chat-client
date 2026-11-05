import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/app/theme.dart';
import 'package:nanb_chat/features/chat/models/sticker_image.dart';
import 'package:nanb_chat/features/chat/widgets/sticker_editor_screen.dart';

// A valid 1x1 PNG.
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==',
);

/// Opens the editor from a button and records what it resolved to.
class _Harness extends StatefulWidget {
  const _Harness({required this.onResult});
  final ValueChanged<StickerImage?> onResult;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ElevatedButton(
          onPressed: () async =>
              widget.onResult(await editSticker(context, _png, 'image/png')),
          child: const Text('open'),
        ),
      ),
    );
  }
}

Future<void> _openEditor(
  WidgetTester tester,
  ValueChanged<StickerImage?> onResult,
) async {
  await tester.pumpWidget(MaterialApp(
    theme: buildLightTheme(),
    home: _Harness(onResult: onResult),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  group('StickerEditorScreen', () {
    testWidgets('Use original hands back the untouched bytes', (tester) async {
      StickerImage? result;
      await _openEditor(tester, (r) => result = r);

      await tester.tap(find.text('Use original'));
      await tester.pumpAndSettle();

      expect(result!.bytes, _png);
      expect(result!.mimeType, 'image/png');
    });

    testWidgets('closing the editor resolves to nothing', (tester) async {
      StickerImage? result = StickerImage(bytes: _png, mimeType: 'x');
      await _openEditor(tester, (r) => result = r);

      await tester.tap(find.byType(CloseButton));
      await tester.pumpAndSettle();

      expect(result, isNull);
    });

    testWidgets('Done returns the cropped frame as a PNG', (tester) async {
      StickerImage? result;
      await _openEditor(tester, (r) => result = r);

      await tester.runAsync(() async {
        await tester.tap(find.text('Done'));
        // Rasterizing happens off the test clock.
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await tester.pumpAndSettle();

      expect(result!.mimeType, 'image/png');
      // PNG signature.
      expect(result!.bytes.take(4), [0x89, 0x50, 0x4E, 0x47]);
    });

    testWidgets('has no drawing surface until Cut out is switched on',
        (tester) async {
      await _openEditor(tester, (_) {});
      expect(find.byKey(const ValueKey('cut-surface')), findsNothing);

      await tester.tap(find.byTooltip('Cut out'));
      await tester.pump();

      expect(find.byKey(const ValueKey('cut-surface')), findsOneWidget);
    });

    testWidgets('Done after tracing a shape returns a smaller cut-out',
        (tester) async {
      StickerImage? result;
      await _openEditor(tester, (r) => result = r);
      await tester.tap(find.byTooltip('Cut out'));
      await tester.pump();

      final surface = tester.getRect(find.byKey(const ValueKey('cut-surface')));
      // Trace a triangle covering the middle half of the frame.
      final gesture = await tester.startGesture(
          surface.center + Offset(-surface.width / 4, surface.height / 4));
      await gesture.moveTo(
          surface.center + Offset(surface.width / 4, surface.height / 4));
      await gesture.moveTo(surface.center + Offset(0, -surface.height / 4));
      await gesture.up();
      await tester.pump();

      await tester.runAsync(() async {
        await tester.tap(find.text('Done'));
        await Future<void>.delayed(const Duration(milliseconds: 400));
      });
      await tester.pumpAndSettle();

      final decoded = await tester.runAsync(() async {
        final codec = await ui.instantiateImageCodec(
            Uint8List.fromList(result!.bytes));
        return (await codec.getNextFrame()).image;
      });
      // Cropped to the outline, so well under the full 512px sticker square.
      expect(decoded!.width, lessThan(400));
    });

    testWidgets('offers rotate, flip and reset controls', (tester) async {
      await _openEditor(tester, (_) {});

      expect(find.byTooltip('Rotate'), findsOneWidget);
      expect(find.byTooltip('Flip'), findsOneWidget);
      expect(find.byTooltip('Reset'), findsOneWidget);
    });
  });
}
