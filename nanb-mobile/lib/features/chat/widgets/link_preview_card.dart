import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../app/theme.dart';
import '../models/link_preview.dart';

/// The card under (inside) a message bubble that shows a linked page's title,
/// description and thumbnail. The whole card is the tap target for the link.
///
/// Coloured from the bubble's own text colour ([color]) so it reads on both the
/// outgoing and incoming bubble backgrounds in light and dark themes.
class LinkPreviewCard extends StatelessWidget {
  const LinkPreviewCard({
    super.key,
    required this.preview,
    required this.color,
    required this.onTap,
  });

  final LinkPreview preview;

  /// The bubble's foreground colour.
  final Color color;
  final VoidCallback onTap;

  static const _thumbSize = 56.0;

  @override
  Widget build(BuildContext context) {
    final host = Uri.tryParse(preview.url)?.host ?? '';
    final thumb = preview.thumbnail;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.09),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (thumb != null && thumb.isNotEmpty) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Image.memory(
                  Uint8List.fromList(thumb),
                  width: _thumbSize,
                  height: _thumbSize,
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                  errorBuilder: (_, _, _) =>
                      const SizedBox(width: _thumbSize, height: _thumbSize),
                ),
              ),
              const SizedBox(width: 8),
            ],
            Flexible(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    preview.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: color,
                      height: 1.25,
                    ),
                  ),
                  if (preview.description.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        preview.description,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: color.withValues(alpha: 0.75),
                          height: 1.3,
                        ),
                      ),
                    ),
                  if (host.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        host,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: monoStyle(
                          fontSize: 10,
                          color: color.withValues(alpha: 0.6),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
