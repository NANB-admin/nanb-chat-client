import 'dart:async';

import '../models/chat_message.dart';
import '../models/conversation_kind.dart';
import '../models/message_control.dart';
import '../models/message_kind.dart';
import 'notifier_service_host.dart';

/// Delivery/read receipts: apply an inbound receipt (advancing outgoing
/// messages' delivery status, monotonically) and mark a conversation read
/// (clear unread + send a read receipt to the 1:1 peer when enabled).
/// Extracted from `ConversationsNotifier`.
class ReceiptService {
  ReceiptService(this._host);

  final NotifierServiceHost _host;

  /// Applies a delivery/read receipt: advances the matching outgoing messages'
  /// [ChatMessage.deliveryStatus]. Monotonic — a late `delivered` never
  /// downgrades a message already marked `read`. The CALLER MUST HOLD the
  /// conversation lock (mutates the live conversation + DB directly).
  Future<void> applyReceipt(
    String conversationId,
    ReceiptKind kind,
    List<String> ids,
  ) async {
    final live = _host.conversation(conversationId);
    if (live == null) return;
    final next = kind == ReceiptKind.read
        ? MessageDeliveryStatus.read
        : MessageDeliveryStatus.delivered;
    final idSet = ids.toSet();
    final now = DateTime.now().toUtc();
    final touched = <ChatMessage>[];
    final rebuilt = <ChatMessage>[
      for (final m in live.messages)
        if (m.mine &&
            idSet.contains(m.envelopeId) &&
            next.index > m.deliveryStatus.index)
          (() {
            // A read receipt implies delivery, so fill in a missing delivered time.
            final nm = m.copyWith(
              deliveryStatus: next,
              deliveredAt: m.deliveredAt ?? now,
              readAt: next == MessageDeliveryStatus.read ? now : null,
            );
            touched.add(nm);
            return nm;
          })()
        else
          m,
    ];
    if (touched.isEmpty) return;
    _host.setConversation(conversationId, live.copyWith(messages: rebuilt));
    await _host.db.upsertMessages(conversationId, touched);
    _host.notifyHost();
  }

  /// Clear [conversationId]'s unread count and, for a 1:1 with read receipts
  /// enabled, send a "read" receipt to the sender. Synchronous (the UI calls it
  /// during build): the DB write + receipt send are fire-and-forget.
  void markRead(String conversationId) {
    final convo = _host.conversation(conversationId);
    if (convo == null || convo.unreadCount == 0) return;
    final updated = convo.copyWith(unreadCount: 0);
    _host.setConversation(conversationId, updated);
    // Best-effort persistence — not awaited so markRead stays sync.
    unawaited(_host.db.upsertConversation(updated));
    _host.notifyHost();

    // Send a "read" receipt to the sender (1:1). Only fires when there were
    // unread messages (early-return above bounds the frequency). Covers the
    // loaded inbound messages; idempotent + monotonic on the sender side.
    // Skipped when the user opted out of read receipts (Privacy setting).
    if (updated.kind == ConversationKind.oneToOne &&
        _host.readReceiptsEnabled) {
      final ids = updated.messages
          .where((m) =>
              !m.mine &&
              m.kind != MessageKind.system &&
              m.envelopeId.isNotEmpty)
          .map((m) => m.envelopeId)
          .toList();
      if (ids.isNotEmpty) {
        unawaited(Future(() => _host.sendControl(
              conversationId,
              MessageControl.receipt(ReceiptKind.read, ids).encode(),
            )));
      }
    }
  }
}
