import 'dart:typed_data';
import 'dart:ui' as ui;

/// Shrinks a downloaded preview image to a small PNG thumbnail that fits inside an
/// encrypted message. Returns null when [bytes] isn't a decodable image or the
/// result is still too large to be worth sending.
class LinkThumbnail {
  const LinkThumbnail._();

  /// Longest side, in pixels. The card shows it at 56 logical px.
  static const maxSide = 96;

  /// Upper bound on the encoded thumbnail.
  static const maxBytes = 40 * 1024;

  static Future<List<int>?> make(List<int> bytes) async {
    try {
      final data = Uint8List.fromList(bytes);
      final probe = await ui.instantiateImageCodec(data);
      final first = (await probe.getNextFrame()).image;
      probe.dispose();
      final longest = first.width > first.height ? first.width : first.height;
      final width = first.width;
      final height = first.height;
      first.dispose();

      final scale = longest > maxSide ? maxSide / longest : 1.0;
      // The engine scales while decoding, so a huge photo is never held at full
      // resolution.
      final codec = await ui.instantiateImageCodec(
        data,
        targetWidth: (width * scale).round().clamp(1, maxSide),
        targetHeight: (height * scale).round().clamp(1, maxSide),
      );
      final scaled = (await codec.getNextFrame()).image;
      codec.dispose();
      final png = await scaled.toByteData(format: ui.ImageByteFormat.png);
      scaled.dispose();
      if (png == null || png.lengthInBytes > maxBytes) return null;
      return png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes);
    } catch (_) {
      return null;
    }
  }
}
