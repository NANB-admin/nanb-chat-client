import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/features/chat/services/sticker_cutter.dart';

/// A solid opaque [size]x[size] image.
Future<ui.Image> _solid(int size) {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(
    ui.Rect.fromLTWH(0, 0, size.toDouble(), size.toDouble()),
    ui.Paint()..color = const ui.Color(0xFFFF0000),
  );
  return recorder.endRecording().toImage(size, size);
}

Future<({int width, int height, Uint8List rgba})> _decode(
    Uint8List png) async {
  final codec = await ui.instantiateImageCodec(png);
  final image = (await codec.getNextFrame()).image;
  final data = (await image.toByteData())!;
  return (
    width: image.width,
    height: image.height,
    rgba: data.buffer.asUint8List(),
  );
}

int _alphaAt(({int width, int height, Uint8List rgba}) img, int x, int y) =>
    img.rgba[(y * img.width + x) * 4 + 3];

void main() {
  const cutter = StickerCutter();
  // A right triangle with corners (10,10), (90,10), (10,90) in a 100px image.
  const triangle = [
    ui.Offset(10, 10),
    ui.Offset(90, 10),
    ui.Offset(10, 90),
  ];

  group('StickerCutter.cutToPng', () {
    testWidgets('crops the result to the outline\'s bounding box',
        (tester) async {
      await tester.runAsync(() async {
        final png = await cutter.cutToPng(await _solid(100), triangle);
        final img = await _decode(png!);

        expect(img.width, 80);
        expect(img.height, 80);
      });
    });

    testWidgets('keeps the pixels inside the outline', (tester) async {
      await tester.runAsync(() async {
        final png = await cutter.cutToPng(await _solid(100), triangle);
        final img = await _decode(png!);

        // Near the triangle's right-angle corner (top-left of the crop).
        expect(_alphaAt(img, 10, 10), 255);
      });
    });

    testWidgets('makes the pixels outside the outline transparent',
        (tester) async {
      await tester.runAsync(() async {
        final png = await cutter.cutToPng(await _solid(100), triangle);
        final img = await _decode(png!);

        // Bottom-right of the crop is beyond the triangle's hypotenuse.
        expect(_alphaAt(img, 75, 75), 0);
      });
    });

    testWidgets('returns null for an outline that encloses nothing',
        (tester) async {
      await tester.runAsync(() async {
        final png = await cutter.cutToPng(
            await _solid(100), const [ui.Offset(5, 5), ui.Offset(50, 50)]);

        expect(png, isNull);
      });
    });

    testWidgets('returns null when the outline lies outside the image',
        (tester) async {
      await tester.runAsync(() async {
        final png = await cutter.cutToPng(await _solid(100), const [
          ui.Offset(200, 200),
          ui.Offset(300, 200),
          ui.Offset(200, 300),
        ]);

        expect(png, isNull);
      });
    });
  });
}
