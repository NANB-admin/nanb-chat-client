import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../core/platform/secure_screen.dart';

/// View-only enlarged profile photo (about 3x the header avatar). Deliberately
/// offers no copy / save / share, and holds the screenshot protection on while
/// open (Android blocks the capture; iOS reports it / covers recordings).
/// Tap anywhere to dismiss.
class AvatarViewerScreen extends StatefulWidget {
  const AvatarViewerScreen({super.key, required this.bytes});

  final Uint8List bytes;

  static Future<void> open(BuildContext context, Uint8List bytes) {
    return Navigator.of(context).push<void>(
      PageRouteBuilder<void>(
        opaque: false,
        barrierColor: Colors.black87,
        barrierDismissible: true,
        pageBuilder: (_, _, _) => AvatarViewerScreen(bytes: bytes),
        transitionsBuilder: (_, animation, _, child) =>
            FadeTransition(opacity: animation, child: child),
      ),
    );
  }

  @override
  State<AvatarViewerScreen> createState() => _AvatarViewerScreenState();
}

class _AvatarViewerScreenState extends State<AvatarViewerScreen> {
  @override
  void initState() {
    super.initState();
    SecureScreen.pushProtected();
  }

  @override
  void dispose() {
    SecureScreen.popProtected();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final side = (width * 0.75).clamp(160.0, 300.0);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => Navigator.of(context).maybePop(),
      child: Material(
        type: MaterialType.transparency,
        child: Center(
          child: ClipOval(
            child: Image.memory(
              widget.bytes,
              width: side,
              height: side,
              fit: BoxFit.cover,
              gaplessPlayback: true,
            ),
          ),
        ),
      ),
    );
  }
}
