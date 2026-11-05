import 'package:flutter/material.dart';

import '../../../app/design_tokens.dart';
import '../models/chat_message.dart';

/// "Message info" for one of your own messages: when it was sent, when it was
/// delivered to the recipient's device, and when they read it.
///
/// "Read" only fills in if the recipient has read receipts turned on — when it is
/// empty the sheet says so rather than guessing.
class MessageInfoSheet extends StatelessWidget {
  const MessageInfoSheet({super.key, required this.message});

  final ChatMessage message;

  static Future<void> show(BuildContext context, ChatMessage message) {
    return showModalBottomSheet<void>(
      context: context,
      builder: (_) => MessageInfoSheet(message: message),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = DesignTokens.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Message info',
                style: TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w600, color: t.text)),
            const SizedBox(height: 16),
            _InfoRow(
              icon: Icons.check,
              label: 'Sent',
              value: formatInfoTime(message.serverTs),
            ),
            _InfoRow(
              icon: Icons.done_all,
              label: 'Delivered',
              value: message.deliveredAt == null
                  ? 'Not yet'
                  : formatInfoTime(message.deliveredAt!),
            ),
            _InfoRow(
              icon: Icons.done_all,
              iconColor: message.readAt == null ? null : t.accent,
              label: 'Read',
              value: message.readAt == null
                  ? 'Not read, or their read receipts are off'
                  : formatInfoTime(message.readAt!),
            ),
          ],
        ),
      ),
    );
  }

  /// "Today, 14:05" / "Yesterday, 09:30" / "3/12/2026, 18:20".
  static String formatInfoTime(DateTime utc, {DateTime? now}) {
    final l = utc.toLocal();
    final today = now ?? DateTime.now();
    final day = DateTime(l.year, l.month, l.day);
    final t0 = DateTime(today.year, today.month, today.day);
    final hhmm =
        '${l.hour.toString().padLeft(2, '0')}:${l.minute.toString().padLeft(2, '0')}';
    if (day == t0) return 'Today, $hhmm';
    if (day == t0.subtract(const Duration(days: 1))) return 'Yesterday, $hhmm';
    return '${l.month}/${l.day}/${l.year}, $hhmm';
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.icon,
    required this.label,
    required this.value,
    this.iconColor,
  });

  final IconData icon;
  final Color? iconColor;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final t = DesignTokens.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: iconColor ?? t.textFaint),
          const SizedBox(width: 12),
          SizedBox(
            width: 84,
            child: Text(label, style: TextStyle(fontSize: 14, color: t.text)),
          ),
          Expanded(
            child: Text(value,
                style: TextStyle(fontSize: 14, color: t.textMuted)),
          ),
        ],
      ),
    );
  }
}
