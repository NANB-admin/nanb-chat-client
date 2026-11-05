import 'dart:typed_data';

import 'package:flutter/material.dart';

/// Full-screen view of a decrypted image: pinch/double-tap to zoom, drag to pan,
/// tap the close button to leave.
class ImageViewerScreen extends StatelessWidget {
  const ImageViewerScreen({super.key, required this.bytes});

  final Uint8List bytes;

  /// Pushes the viewer over the current route.
  static Future<void> open(BuildContext context, Uint8List bytes) {
    return Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => ImageViewerScreen(bytes: bytes),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          Positioned.fill(
            child: InteractiveViewer(
              minScale: 1,
              maxScale: 6,
              child: SizedBox.fromSize(
                size: MediaQuery.sizeOf(context),
                // Natural size; only shrunk when larger than the screen.
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Image.memory(bytes),
                ),
              ),
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: IconButton(
                tooltip: 'Close',
                icon: const Icon(Icons.close, color: Colors.white),
                onPressed: () => Navigator.of(context).maybePop(),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
