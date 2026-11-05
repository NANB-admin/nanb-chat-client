import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../app/design_tokens.dart';
import '../../../app/theme.dart';

/// Video-attachment bubble. Renders a 16:9 thumbnail (if available) or a
/// black surface, with a centered play-circle, an AES-GCM badge with size +
/// time, and an optional caption. Tapping invokes [onTap] (the chat-thread
/// screen pushes the fullscreen player route).
class MessageBubbleVideo extends StatelessWidget {
  const MessageBubbleVideo({
    super.key,
    required this.size,
    required this.time,
    required this.mine,
    this.caption = '',
    this.onTap,
    this.thumbnail,
  });

  /// Human-formatted byte size (e.g., "12.3 MB"). Caller owns formatting.
  final String size;
  final String time;
  final bool mine;
  final String caption;
  final VoidCallback? onTap;

  /// Optional first-frame thumbnail bytes (JPEG/PNG). When non-null, renders
  /// as the bubble's 16:9 background under the play-circle. When null, falls
  /// back to a plain black surface (still decoding, or generator failed).
  final Uint8List? thumbnail;

  @override
  Widget build(BuildContext context) {
    final t = DesignTokens.of(context);
    final bg = mine ? t.bubbleOut : t.bubbleIn;
    final fg = mine ? t.bubbleOutText : t.text;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 3),
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.78,
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
                child: AspectRatio(
                  aspectRatio: 16 / 9,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (thumbnail != null)
                        Image.memory(
                          thumbnail!,
                          fit: BoxFit.cover,
                          gaplessPlayback: true,
                        )
                      else
                        Container(color: Colors.black),
                      Center(
                        child: Container(
                          width: 56,
                          height: 56,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: Colors.black54,
                            shape: BoxShape.circle,
                            border:
                                Border.all(color: Colors.white70, width: 1.5),
                          ),
                          child: const Icon(Icons.play_arrow,
                              color: Colors.white, size: 28),
                        ),
                      ),
                    ],
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
                        const SizedBox(width: 8),
                        Text(
                          size,
                          style: monoStyle(
                            fontSize: 9.5,
                            color: fg.withValues(alpha: 0.7),
                            letterSpacing: 0.3,
                          ),
                        ),
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
                    if (caption.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        caption,
                        style: TextStyle(fontSize: 14, color: fg, height: 1.3),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
