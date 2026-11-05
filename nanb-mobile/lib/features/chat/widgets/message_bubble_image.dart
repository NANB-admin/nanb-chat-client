import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../app/design_tokens.dart';
import '../../../app/theme.dart';

/// Image-attachment bubble. Renders one of two states based on `bytes`:
///
/// - `bytes == null` → encrypted-placeholder (diagonal stripes + "decrypting…"
///   label). Used while the media pipeline fetches + decrypts the blob, or
///   for pre-staged design-only screens.
/// - `bytes != null` → `Image.memory(bytes)` of the decrypted image.
///
/// In both states the AES-GCM badge, optional size label, time, and optional
/// caption render in the same layout so the bubble doesn't reflow on decrypt.
class MessageBubbleImage extends StatelessWidget {
  const MessageBubbleImage({
    super.key,
    required this.time,
    required this.mine,
    this.caption,
    this.size,
    this.bytes,
    this.onTap,
  });

  /// "10:14" wall-clock label shown in the corner, like `MessageBubble`.
  final String time;
  final bool mine;
  final String? caption;
  final String? size;

  /// Decrypted image bytes. `null` while still encrypted/loading — the bubble
  /// renders the stripe placeholder until they arrive.
  final Uint8List? bytes;

  /// Tapping the picture (once decrypted) opens it full screen.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = DesignTokens.of(context);
    final bg = mine ? t.bubbleOut : t.bubbleIn;
    final fg = mine ? t.bubbleOutText : t.text;
    final media = MediaQuery.of(context);
    final maxWidth = media.size.width * 0.78;
    // Cap the inline decode to the bubble's on-screen pixel width. Without a
    // cacheWidth a large source (e.g. 2048²) decodes to full-resolution RGBA
    // (~16.8 MB) just to paint a ~300px-wide preview. Only the width is capped
    // so the decoder keeps the aspect ratio (height follows), matching the
    // BoxFit.fitWidth layout below. The full-screen viewer is a separate widget
    // and still decodes at native resolution.
    final decodeWidth = (maxWidth * media.devicePixelRatio).round();
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 3),
        constraints: BoxConstraints(
          maxWidth: maxWidth,
        ),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: mine ? Colors.transparent : t.bubbleInBorder),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipRRect(
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(13),
                topRight: Radius.circular(13),
              ),
              child: bytes == null
                  ? AspectRatio(aspectRatio: 4 / 3, child: _StripePattern(t: t))
                  // Fill the bubble width so a small image/GIF doesn't leave a
                  // margin of bubble background showing on the sides (the "white
                  // border"). fitWidth scales to the full width with height kept
                  // proportional — no crop. gaplessPlayback keeps the current
                  // frame painted while a new provider resolves, so a rebuild
                  // never flashes a blank gap.
                  : GestureDetector(
                      onTap: onTap,
                      child: Image.memory(
                        bytes!,
                        width: double.infinity,
                        fit: BoxFit.fitWidth,
                        cacheWidth: decodeWidth > 0 ? decodeWidth : null,
                        gaplessPlayback: true,
                      ),
                    ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Icon(Icons.lock, size: 11, color: fg.withValues(alpha: 0.7)),
                      const SizedBox(width: 4),
                      Text(
                        'AES-GCM',
                        style: monoStyle(
                          fontSize: 9.5,
                          color: fg.withValues(alpha: 0.7),
                          letterSpacing: 0.3,
                        ),
                      ),
                      if (size != null) ...[
                        const SizedBox(width: 8),
                        Text(
                          size!,
                          style: monoStyle(
                            fontSize: 9.5,
                            color: fg.withValues(alpha: 0.7),
                            letterSpacing: 0.3,
                          ),
                        ),
                      ],
                      const Spacer(),
                      Text(
                        time,
                        style: monoStyle(
                          fontSize: 9.5,
                          color: fg.withValues(alpha: 0.7),
                          letterSpacing: 0.3,
                        ),
                      ),
                    ],
                  ),
                  if (caption != null && caption!.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      caption!,
                      style: TextStyle(fontSize: 14, color: fg, height: 1.3),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StripePattern extends StatelessWidget {
  const _StripePattern({required this.t});
  final DesignTokens t;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _StripePainter(
        baseColor: t.surfaceAlt,
        stripeColor: t.border,
      ),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.45),
            borderRadius: BorderRadius.circular(6),
          ),
          child: const Text(
            'image · encrypted',
            style: TextStyle(color: Colors.white, fontSize: 11),
          ),
        ),
      ),
    );
  }
}

class _StripePainter extends CustomPainter {
  _StripePainter({required this.baseColor, required this.stripeColor});
  final Color baseColor;
  final Color stripeColor;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = baseColor);
    final paint = Paint()
      ..color = stripeColor
      ..strokeWidth = 1;
    const spacing = 12.0;
    final maxStart = size.width + size.height;
    for (var x = -size.height; x < maxStart; x += spacing) {
      canvas.drawLine(Offset(x, 0), Offset(x + size.height, size.height), paint);
    }
  }

  @override
  bool shouldRepaint(_StripePainter oldDelegate) =>
      oldDelegate.baseColor != baseColor || oldDelegate.stripeColor != stripeColor;
}
