import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/features/chat/services/link_thumbnail.dart';

Future<Uint8List> _png(int width, int height) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(
    ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    ui.Paint()..color = const ui.Color(0xFF3366CC),
  );
  final image = await recorder.endRecording().toImage(width, height);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}

Future<ui.Image> _decode(List<int> bytes) async {
  final codec = await ui.instantiateImageCodec(Uint8List.fromList(bytes));
  return (await codec.getNextFrame()).image;
}

void main() {
  group('LinkThumbnail.make', () {
    testWidgets('scales the longest side down to the maximum', (tester) async {
      await tester.runAsync(() async {
        final thumb = await LinkThumbnail.make(await _png(1000, 500));
        final image = await _decode(thumb!);

        expect(image.width, LinkThumbnail.maxSide);
      });
    });

    testWidgets('keeps the aspect ratio', (tester) async {
      await tester.runAsync(() async {
        final thumb = await LinkThumbnail.make(await _png(1000, 500));
        final image = await _decode(thumb!);

        expect(image.height, LinkThumbnail.maxSide ~/ 2);
      });
    });

    testWidgets('does not enlarge a small image', (tester) async {
      await tester.runAsync(() async {
        final thumb = await LinkThumbnail.make(await _png(40, 30));
        final image = await _decode(thumb!);

        expect(image.width, 40);
      });
    });

    testWidgets('returns null for bytes that are not an image', (tester) async {
      await tester.runAsync(() async {
        expect(await LinkThumbnail.make([1, 2, 3, 4]), isNull);
      });
    });
  });
}
