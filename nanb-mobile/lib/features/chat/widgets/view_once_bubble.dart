import 'package:flutter/material.dart';

import '../../../app/design_tokens.dart';
import '../models/chat_message.dart';
import '../models/message_kind.dart';

/// Stands in for a view-once message in the thread. It never shows the content:
/// the recipient taps it to open the viewer once; afterwards, and always on the
/// sender's side, it only says what it was and whether it was opened.
class ViewOnceBubble extends StatelessWidget {
  const ViewOnceBubble({
    super.key,
    required this.message,
    required this.time,
    this.onOpen,
    this.onRetry,
  });

  final ChatMessage message;
  final String time;

  /// Opens it. Null when it can't be opened here (ours, opened, or not yet sent).
  final VoidCallback? onOpen;

  /// Re-sends our own message that failed to send.
  final VoidCallback? onRetry;

  static String kindLabel(MessageKind kind) => switch (kind) {
        MessageKind.image => 'Photo',
        MessageKind.video => 'Video',
        MessageKind.voice => 'Voice message',
        _ => 'Message',
      };

  /// The line shown for a view-once message here and in the chat list.
  static String label(ChatMessage m) {
    if (m.viewOnceOpenedAt != null) return 'Opened';
    return '${kindLabel(m.kind)} · View once';
  }

  @override
  Widget build(BuildContext context) {
    final t = DesignTokens.of(context);
    final opened = message.viewOnceOpenedAt != null;
    final color = message.mine ? t.accentOn : t.text;
    final bubble = Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: message.mine ? t.accent : t.surfaceAlt,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: t.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(opened ? Icons.radio_button_unchecked : Icons.looks_one,
              size: 18, color: color),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              label(message),
              style: TextStyle(
                fontSize: 14,
                color: color,
                fontStyle: opened ? FontStyle.italic : FontStyle.normal,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(time,
              style: TextStyle(fontSize: 11, color: color.withValues(alpha: 0.7))),
        ],
      ),
    );
    // Our own message still going out, or stuck: said underneath, never on top,
    // because the bubble is too small for an overlay to leave the label legible.
    final status = !message.mine
        ? null
        : message.failed
            ? GestureDetector(
                onTap: onRetry,
                child: Text('Not sent · Tap to retry',
                    style: TextStyle(fontSize: 11, color: Colors.red.shade400)),
              )
            : message.uploading ||
                    (message.outboxId != null && message.outboxId!.isNotEmpty)
                ? Text('Sending…',
                    style: TextStyle(fontSize: 11, color: t.textFaint))
                : null;
    if (status != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          bubble,
          Padding(padding: const EdgeInsets.only(top: 3, right: 2), child: status),
        ],
      );
    }
    if (onOpen == null) return bubble;
    return Semantics(
      button: true,
      label: 'Open ${kindLabel(message.kind).toLowerCase()}, view once',
      child: GestureDetector(onTap: onOpen, child: bubble),
    );
  }
}
