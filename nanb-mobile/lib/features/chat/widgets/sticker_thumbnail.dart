import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../models/sticker.dart';

/// Renders a [Sticker] (bundled asset or user file) at picker size. The decode
/// is capped near the on-screen pixel size so a grid of dozens stays cheap.
class StickerThumbnail extends StatelessWidget {
  const StickerThumbnail({super.key, required this.sticker, this.size});

  final Sticker sticker;

  /// Fixed edge length, or null to fill the available space.
  final double? size;

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.of(context).devicePixelRatio;
    final decodeWidth = ((size ?? 120) * dpr).round();
    final asset = sticker.assetPath;
    if (asset != null) {
      return Image.asset(
        asset,
        width: size,
        height: size,
        cacheWidth: decodeWidth,
        fit: BoxFit.contain,
        gaplessPlayback: true,
      );
    }
    return _FileSticker(
      path: sticker.filePath!,
      size: size,
      decodeWidth: decodeWidth,
    );
  }
}

/// A user-made sticker. Its bytes are read into memory once and shown with
/// `Image.memory` rather than `Image.file`: that leaves no open file handle on
/// the sticker, so removing it from disk never races the image decoder.
class _FileSticker extends StatefulWidget {
  const _FileSticker({
    required this.path,
    required this.size,
    required this.decodeWidth,
  });

  final String path;
  final double? size;
  final int decodeWidth;

  @override
  State<_FileSticker> createState() => _FileStickerState();
}

class _FileStickerState extends State<_FileSticker> {
  Uint8List? _bytes;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _read();
  }

  Future<void> _read() async {
    try {
      final bytes = await File(widget.path).readAsBytes();
      if (mounted) setState(() => _bytes = bytes);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_failed) return const Icon(Icons.broken_image_outlined);
    final bytes = _bytes;
    if (bytes == null) return SizedBox(width: widget.size, height: widget.size);
    return Image.memory(
      bytes,
      width: widget.size,
      height: widget.size,
      cacheWidth: widget.decodeWidth,
      fit: BoxFit.contain,
      gaplessPlayback: true,
    );
  }
}
