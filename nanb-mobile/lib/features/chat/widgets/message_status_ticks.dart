import 'package:flutter/material.dart';

import '../../../app/design_tokens.dart';
import '../models/chat_message.dart';

/// WhatsApp-style delivery ticks for one of MY outgoing messages:
///   * a clock while the send is pending / a media upload is in flight,
///   * a single ✓ once sent (OPTIMISTIC — shown the instant it's on screen,
///     before the server ack, so a queued send doesn't sit on a clock),
///   * ✓✓ once the peer's device received (decrypted) it,
///   * accent-coloured ✓✓ once the peer read the conversation,
///   * an error mark when the send ultimately failed.
///
/// Renders nothing for a message that isn't [ChatMessage.mine]. Shared by the
/// chat-list last-message preview and (the same tick vocabulary as) the thread
/// bubble so both surfaces agree.
class MessageStatusTicks extends StatelessWidget {
  const MessageStatusTicks({
    super.key,
    required this.message,
    required this.t,
    this.size = 13,
  });

  final ChatMessage message;
  final DesignTokens t;
  final double size;

  @override
  Widget build(BuildContext context) {
    if (!message.mine) return const SizedBox.shrink();
    if (message.failed) {
      return Icon(Icons.error_outline, size: size, color: t.warn);
    }
    if (message.uploading) {
      return Icon(Icons.schedule, size: size, color: t.textFaint);
    }
    // Not yet server-acked (still has an outbox id) → optimistic single ✓.
    final acked = message.outboxId == null || message.outboxId!.isEmpty;
    if (!acked) {
      return Icon(Icons.check, size: size, color: t.textFaint);
    }
    switch (message.deliveryStatus) {
      case MessageDeliveryStatus.sent:
        return Icon(Icons.check, size: size, color: t.textFaint);
      case MessageDeliveryStatus.delivered:
        return Icon(Icons.done_all, size: size, color: t.textFaint);
      case MessageDeliveryStatus.read:
        return Icon(Icons.done_all, size: size, color: t.accent);
    }
  }
}
