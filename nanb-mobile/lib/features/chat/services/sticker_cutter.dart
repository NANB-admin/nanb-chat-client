import 'dart:typed_data';
import 'dart:ui' as ui;

/// Cuts a freehand-drawn shape out of an image: everything outside the outline
/// becomes transparent, and the result is cropped to the outline's bounding box
/// so the sticker has no dead space around the subject.
class StickerCutter {
  const StickerCutter();

  /// Fewest outline points that can enclose an area.
  static const minPoints = 3;

  /// Returns the cut-out as PNG bytes, or null when [outline] is too small to
  /// enclose anything (a tap, a straight line) or lies outside [source].
  ///
  /// [outline] is in [source] pixel coordinates; the last point is joined back to
  /// the first.
  Future<Uint8List?> cutToPng(ui.Image source, List<ui.Offset> outline) async {
    if (outline.length < minPoints) return null;
    final path = ui.Path()..addPolygon(outline, true);
    final bounds = path
        .getBounds()
        .intersect(ui.Rect.fromLTWH(0, 0, source.width.toDouble(), source.height.toDouble()));
    final width = bounds.width.ceil();
    final height = bounds.height.ceil();
    if (width < 1 || height < 1) return null;

    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.translate(-bounds.left, -bounds.top);
    canvas.clipPath(path); // anti-aliased edge
    canvas.drawImage(source, ui.Offset.zero, ui.Paint());
    final picture = recorder.endRecording();
    final cut = await picture.toImage(width, height);
    picture.dispose();
    final png = await cut.toByteData(format: ui.ImageByteFormat.png);
    cut.dispose();
    if (png == null) return null;
    return png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes);
  }
}
