import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../../app/design_tokens.dart';
import '../models/sticker_image.dart';
import '../services/sticker_cutter.dart';
import '../services/sticker_normalizer.dart';
import 'lasso_painter.dart';

/// Opens the sticker editor over [bytes] and resolves to the finished image, or
/// null when the user backs out.
Future<StickerImage?> editSticker(
  BuildContext context,
  List<int> bytes,
  String mimeType,
) {
  return Navigator.of(context).push<StickerImage>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => StickerEditorScreen(bytes: bytes, mimeType: mimeType),
    ),
  );
}

/// Crop / rotate / flip / cut out an image before it becomes a sticker.
///
/// The square frame IS the crop: whatever is inside it when the user taps Done
/// is what the sticker contains, so pinching and dragging the image is the
/// cropping gesture. "Cut out" mode lets the user trace around the part they
/// want with a finger; everything outside the outline becomes transparent. The
/// result is a PNG at the sticker size (transparency is kept). "Use original" skips editing and hands back the untouched bytes, which
/// is also how an animated GIF/WebP stays animated (editing flattens it to one
/// frame).
class StickerEditorScreen extends StatefulWidget {
  const StickerEditorScreen({
    super.key,
    required this.bytes,
    required this.mimeType,
  });

  final List<int> bytes;
  final String mimeType;

  @override
  State<StickerEditorScreen> createState() => _StickerEditorScreenState();
}

class _StickerEditorScreenState extends State<StickerEditorScreen> {
  final GlobalKey _frameKey = GlobalKey();
  final TransformationController _view = TransformationController();
  late final Uint8List _bytes = Uint8List.fromList(widget.bytes);

  int _quarterTurns = 0;
  bool _flipped = false;
  bool _busy = false;

  /// Cut-out mode: a finger draws [_outline] instead of moving the image.
  bool _cutMode = false;

  /// The traced outline, in frame (logical pixel) coordinates.
  List<Offset> _outline = const [];

  @override
  void dispose() {
    _view.dispose();
    super.dispose();
  }

  // Any change to the picture under the outline invalidates the outline.
  void _rotate() => setState(() {
        _quarterTurns = (_quarterTurns + 3) % 4;
        _outline = const [];
      });

  void _flip() => setState(() {
        _flipped = !_flipped;
        _outline = const [];
      });

  void _reset() {
    _view.value = Matrix4.identity();
    setState(() {
      _quarterTurns = 0;
      _flipped = false;
      _cutMode = false;
      _outline = const [];
    });
  }

  void _toggleCut() => setState(() {
        _cutMode = !_cutMode;
        _outline = const [];
      });

  void _startOutline(Offset at) => setState(() => _outline = [at]);

  void _extendOutline(Offset to) => setState(() => _outline = [..._outline, to]);

  void _useOriginal() {
    Navigator.of(context).pop(
      StickerImage(bytes: widget.bytes, mimeType: widget.mimeType),
    );
  }

  Future<void> _done() async {
    if (_busy) return;
    setState(() => _busy = true);
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final boundary = _frameKey.currentContext!.findRenderObject()!
          as RenderRepaintBoundary;
      final ratio = StickerNormalizer.maxSide / boundary.size.width;
      final image = await boundary.toImage(pixelRatio: ratio);
      Uint8List? bytes;
      if (_cutMode && _outline.length >= StickerCutter.minPoints) {
        bytes = await const StickerCutter().cutToPng(
          image,
          [for (final p in _outline) p * ratio],
        );
        if (bytes == null) {
          image.dispose();
          if (!mounted) return;
          setState(() => _busy = false);
          messenger.showSnackBar(
            const SnackBar(content: Text('Draw around the part you want.')),
          );
          return;
        }
      } else {
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        if (png != null) {
          bytes = png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes);
        }
      }
      image.dispose();
      if (bytes == null) throw StateError('encode failed');
      navigator.pop(StickerImage(bytes: bytes, mimeType: 'image/png'));
    } catch (_) {
      if (!mounted) return;
      setState(() => _busy = false);
      messenger.showSnackBar(
        const SnackBar(content: Text("Couldn't edit that image.")),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = DesignTokens.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Edit sticker'),
        actions: [
          TextButton(
            onPressed: _busy ? null : _useOriginal,
            child: const Text('Use original'),
          ),
          TextButton(
            onPressed: _busy ? null : _done,
            child: const Text('Done'),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: LayoutBuilder(
                  builder: (context, box) {
                    final side = box.biggest.shortestSide;
                    return Center(child: _frame(t, side));
                  },
                ),
              ),
            ),
            Text(
              _cutMode
                  ? 'Draw around the part you want to keep'
                  : 'Pinch and drag to crop',
              style: TextStyle(color: t.textMuted, fontSize: 12),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    tooltip: 'Cut out',
                    isSelected: _cutMode,
                    onPressed: _toggleCut,
                    icon: const Icon(Icons.gesture),
                  ),
                  IconButton(
                    tooltip: 'Rotate',
                    onPressed: _rotate,
                    icon: const Icon(Icons.rotate_left),
                  ),
                  IconButton(
                    tooltip: 'Flip',
                    onPressed: _flip,
                    icon: const Icon(Icons.flip),
                  ),
                  IconButton(
                    tooltip: 'Reset',
                    onPressed: _reset,
                    icon: const Icon(Icons.restart_alt),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The square crop window. Only the [RepaintBoundary] is captured, so the
  /// outline drawn over it never ends up in the sticker.
  Widget _frame(DesignTokens t, double side) {
    return SizedBox.square(
      dimension: side,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ColoredBox(color: t.surfaceAlt),
          RepaintBoundary(
            key: _frameKey,
            child: ClipRect(
              child: InteractiveViewer(
                transformationController: _view,
                // In cut-out mode the finger draws, so the image stays put.
                panEnabled: !_cutMode,
                scaleEnabled: !_cutMode,
                minScale: 0.3,
                maxScale: 8,
                boundaryMargin: const EdgeInsets.all(double.infinity),
                child: SizedBox.square(
                  dimension: side,
                  child: Center(
                    child: Transform.flip(
                      flipX: _flipped,
                      child: RotatedBox(
                        quarterTurns: _quarterTurns,
                        child: Image.memory(_bytes, fit: BoxFit.contain),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (_cutMode)
            GestureDetector(
              key: const ValueKey('cut-surface'),
              behavior: HitTestBehavior.opaque,
              onPanStart: (d) => _startOutline(d.localPosition),
              onPanUpdate: (d) => _extendOutline(d.localPosition),
              child: CustomPaint(
                painter: LassoPainter(points: _outline, color: t.accent),
              ),
            ),
          IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                border: Border.all(color: t.accent, width: 2),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
