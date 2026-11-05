import 'package:flutter/material.dart';

import '../../../app/design_tokens.dart';
import '../../../app/theme.dart';

/// File-attachment bubble. Renders a file icon + filename + size + AES-GCM
/// badge. Tapping invokes [onTap] (the chat-thread screen triggers a
/// download + open).
class MessageBubbleFile extends StatelessWidget {
  const MessageBubbleFile({
    super.key,
    required this.filename,
    required this.size,
    required this.time,
    required this.mine,
    this.onTap,
    this.caption = '',
  });

  /// Optional text sent with the file; rendered under the file card.
  final String caption;

  final String filename;

  /// Human-formatted size (e.g., "2.4 MB"). Caller owns the formatting; this
  /// widget only renders.
  final String size;
  final String time;
  final bool mine;
  final VoidCallback? onTap;

  IconData get _icon {
    final lower = filename.toLowerCase();
    if (lower.endsWith('.pdf')) return Icons.picture_as_pdf_outlined;
    if (lower.endsWith('.zip') || lower.endsWith('.tar') || lower.endsWith('.gz')) {
      return Icons.archive_outlined;
    }
    if (lower.endsWith('.doc') || lower.endsWith('.docx')) return Icons.article_outlined;
    if (lower.endsWith('.xls') || lower.endsWith('.xlsx') || lower.endsWith('.csv')) {
      return Icons.table_chart_outlined;
    }
    return Icons.insert_drive_file_outlined;
  }

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
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.78,
          ),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: mine ? Colors.transparent : t.bubbleInBorder),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                width: 36,
                height: 36,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: t.surfaceAlt,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: t.border),
                ),
                child: Icon(_icon, size: 18, color: fg),
              ),
              const SizedBox(width: 10),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      filename,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 14, color: fg),
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Icon(Icons.lock, size: 10, color: fg.withValues(alpha: 0.65)),
                        const SizedBox(width: 3),
                        Text(
                          'AES-GCM · $size',
                          style: monoStyle(
                            fontSize: 10,
                            color: fg.withValues(alpha: 0.65),
                            letterSpacing: 0.3,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          time,
                          style: monoStyle(
                            fontSize: 10,
                            color: fg.withValues(alpha: 0.65),
                            letterSpacing: 0.3,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
              if (caption.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(caption, style: TextStyle(fontSize: 14, color: fg)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
