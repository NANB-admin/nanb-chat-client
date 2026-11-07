import 'dart:async';

import '../models/chat_message.dart';
import '../models/conversation.dart';
import '../models/conversation_kind.dart';
import '../models/message_control.dart';
import '../models/message_kind.dart';
import 'notifier_service_host.dart';
import 'transport_receipt_log.dart';

/// Delivery/read receipts: apply an inbound receipt (advancing outgoing
/// messages' delivery status, monotonically) and mark a conversation read
/// (clear unread + send a read receipt to the 1:1 peer when enabled).
/// Extracted from `ConversationsNotifier`.
class ReceiptService {
  ReceiptService(this._host, {TransportReceiptLog? transportReceipts})
      : _transportReceipts = transportReceipts;

  final NotifierServiceHost _host;
  final TransportReceiptLog? _transportReceipts;

  /// Applies a delivery/read receipt: advances the matching outgoing messages'
  /// [ChatMessage.deliveryStatus]. Monotonic — a late `delivered` never
  /// downgrades a message already marked `read`. The CALLER MUST HOLD the
  /// conversation lock (mutates the live conversation + DB directly).
  ///
  /// [ids] may name a message by envelope id or client message id. [transportOnly]
  /// marks evidence that the envelope landed, not that it could be decrypted: the
  /// tick still shows, but the message stays eligible for a resend.
  Future<void> applyReceipt(
    String conversationId,
    ReceiptKind kind,
    List<String> ids, {
    bool transportOnly = false,
  }) async {
    final live = _host.conversation(conversationId);
    if (live == null) return;
    final next = kind == ReceiptKind.read
        ? MessageDeliveryStatus.read
        : MessageDeliveryStatus.delivered;
    final idSet = ids.toSet();
    bool matches(ChatMessage m) =>
        idSet.contains(m.envelopeId) ||
        (m.clientMsgId != null && idSet.contains(m.clientMsgId));
    await _recordEvidence(live, matches, next, transportOnly);
    final now = DateTime.now().toUtc();
    final touched = <ChatMessage>[];
    final rebuilt = <ChatMessage>[
      for (final m in live.messages)
        if (m.mine && matches(m) && next.index > m.deliveryStatus.index)
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

  /// Keeps [TransportReceiptLog] in step: a transport receipt marks a message that
  /// has no better evidence yet, and an end-to-end receipt clears the mark.
  Future<void> _recordEvidence(
    Conversation live,
    bool Function(ChatMessage) matches,
    MessageDeliveryStatus next,
    bool transportOnly,
  ) async {
    final log = _transportReceipts;
    if (log == null) return;
    for (final m in live.messages) {
      if (!m.mine || !matches(m)) continue;
      if (!transportOnly) {
        await log.remove(m.envelopeId);
      } else if (next.index > m.deliveryStatus.index) {
        await log.add(m.envelopeId);
      }
    }
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
          .expand((m) => [m.envelopeId, ?m.clientMsgId])
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
