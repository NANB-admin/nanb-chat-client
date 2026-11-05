import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/features/chat/services/sticker_normalizer.dart';

/// Encodes a solid [width]x[height] image as PNG.
Future<Uint8List> _png(int width, int height) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(
    ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    ui.Paint()..color = const ui.Color(0xFF336699),
  );
  final image = await recorder.endRecording().toImage(width, height);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}

Future<ui.Size> _sizeOf(List<int> bytes) async {
  final codec = await ui.instantiateImageCodec(Uint8List.fromList(bytes));
  final image = (await codec.getNextFrame()).image;
  final size = ui.Size(image.width.toDouble(), image.height.toDouble());
  image.dispose();
  codec.dispose();
  return size;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const normalizer = StickerNormalizer();

  test('keeps a small image byte-for-byte', () async {
    final bytes = await _png(64, 64);

    final result = await normalizer.normalize(bytes, 'image/png');

    expect(result!.bytes, bytes);
  });

  test('keeps the original mime type of a small image', () async {
    final bytes = await _png(64, 64);

    final result = await normalizer.normalize(bytes, 'image/webp');

    expect(result!.mimeType, 'image/webp');
  });

  test('scales a large landscape image down to the max side', () async {
    final bytes = await _png(1024, 512);

    final result = await normalizer.normalize(bytes, 'image/png');

    expect(await _sizeOf(result!.bytes), const ui.Size(512, 256));
  });

  test('scales a large portrait image down to the max side', () async {
    final bytes = await _png(400, 1600);

    final result = await normalizer.normalize(bytes, 'image/png');

    expect(await _sizeOf(result!.bytes), const ui.Size(128, 512));
  });

  test('re-encodes a downscaled image as PNG', () async {
    final bytes = await _png(1024, 1024);

    final result = await normalizer.normalize(bytes, 'image/jpeg');

    expect(result!.mimeType, 'image/png');
  });

  test('returns null for bytes that are not an image', () async {
    final result = await normalizer.normalize([1, 2, 3, 4], 'image/png');

    expect(result, isNull);
  });
}
