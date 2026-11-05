import 'dart:typed_data';
import 'dart:ui' as ui;

import '../models/sticker_image.dart';

/// Turns an arbitrary picked or received image into something fit to be a
/// sticker: small enough to send quickly and to keep dozens on disk.
///
/// An image already within [maxSide] pixels and [maxKeepBytes] is kept exactly
/// as it is — so a small animated GIF/WebP stays animated. Anything larger is
/// scaled down (aspect ratio preserved) and re-encoded as PNG, which keeps
/// transparency but flattens an animation to its first frame.
class StickerNormalizer {
  const StickerNormalizer();

  static const maxSide = 512;
  static const maxKeepBytes = 600 * 1024;

  /// Returns null when [bytes] can't be decoded as an image.
  Future<StickerImage?> normalize(List<int> bytes, String mimeType) async {
    final data = Uint8List.fromList(bytes);
    final ui.Image first;
    try {
      final codec = await ui.instantiateImageCodec(data);
      first = (await codec.getNextFrame()).image;
      codec.dispose();
    } catch (_) {
      return null;
    }
    final width = first.width;
    final height = first.height;
    first.dispose();

    final longest = width > height ? width : height;
    if (longest <= maxSide && data.length <= maxKeepBytes) {
      return StickerImage(bytes: data, mimeType: mimeType);
    }

    // Decode at the target size (the engine scales while decoding, so a huge
    // photo is never held at full resolution), then re-encode as PNG.
    final scale = longest > maxSide ? maxSide / longest : 1.0;
    final codec = await ui.instantiateImageCodec(
      data,
      targetWidth: (width * scale).round().clamp(1, maxSide),
      targetHeight: (height * scale).round().clamp(1, maxSide),
    );
    final scaled = (await codec.getNextFrame()).image;
    codec.dispose();
    final png = await scaled.toByteData(format: ui.ImageByteFormat.png);
    scaled.dispose();
    if (png == null) return null;
    return StickerImage(
      bytes: png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes),
      mimeType: 'image/png',
    );
  }
}
