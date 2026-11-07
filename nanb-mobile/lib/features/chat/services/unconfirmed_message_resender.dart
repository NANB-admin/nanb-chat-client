import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../../core/crypto/crypto_bridge.dart';
import '../../../core/models/envelope.dart' as wire;
import '../../../core/network/api_client.dart';
import '../../../core/push/push_kind.dart';
import '../models/chat_message.dart';
import '../models/conversation.dart';
import '../models/conversation_kind.dart';
import '../models/crypto_mode.dart';
import 'notifier_service_host.dart';
import 'resend_ledger.dart';
import 'resend_wire_body.dart';
import 'transport_receipt_log.dart';

/// Makes 1:1 delivery at-least-once: after this device builds or joins a new MLS
/// group, it re-encrypts and re-sends its own messages the peer never confirmed.
///
/// MLS is forward-secret, so a message sealed to a group the recipient no longer
/// holds can never be opened there, however many times it is redelivered. Every
/// way the two sides can diverge (a rebuilt store, a Welcome collision, a dead
/// key package) used to lose whatever was in flight, silently and for good.
/// The sender is the one party that still has the plaintext, and a group change
/// is the moment both sides can read each other again, so that is when it resends.
///
/// A periodic [sweep] also retries on a growing backoff, for the message that was
/// lost with no group change at all, and collects a resend still owed after the
/// app was killed.
///
/// Safe to over-send: each copy carries the original `_cid`, so the receiver
/// renders it once, and re-confirms it so the sender stops. Silent, because the
/// original already raised the notification. Bounded per message and per run.
class UnconfirmedMessageResender {
  UnconfirmedMessageResender({
    required NotifierServiceHost host,
    required CryptoBridge crypto,
    required TransportReceiptLog transportReceipts,
    required ResendLedger ledger,
    required Future<List<({String accountId, String deviceId})>> Function(
            Conversation)
        fanoutRecipients,
    Duration Function()? settleDelay,
    DateTime Function()? clock,
  })  : _host = host,
        _crypto = crypto,
        _transportReceipts = transportReceipts,
        _ledger = ledger,
        _fanoutRecipients = fanoutRecipients,
        _settleDelay = settleDelay ?? (() => const Duration(seconds: 2)),
        _clock = clock ?? (() => DateTime.now().toUtc());

  final NotifierServiceHost _host;
  final CryptoBridge _crypto;
  final TransportReceiptLog _transportReceipts;
  final ResendLedger _ledger;
  final Future<List<({String accountId, String deviceId})>> Function(
      Conversation) _fanoutRecipients;
  final Duration Function() _settleDelay;
  final DateTime Function() _clock;

  /// A chat that keeps forking must not grow its resends without limit.
  static const int _maxAttemptsPerMessage = 8;

  /// How long a sweep waits before each retry, counted from the send or from the
  /// previous attempt. Its length is also the sweep's budget, so a peer who is
  /// simply offline gets a few silent copies rather than one per reconnect, and
  /// the rest of [_maxAttemptsPerMessage] stays available for a group change.
  static const List<Duration> _sweepBackoff = [
    Duration(minutes: 2),
    Duration(minutes: 10),
    Duration(hours: 1),
  ];
  static const int _maxMessagesPerRun = 50;
  static const Duration _resendWindow = Duration(days: 14);

  final Map<String, Timer> _timers = {};

  /// Call when [conversationId]'s MLS group was just built or adopted. Debounced,
  /// so a burst of changes resends once, into the group that won. Safe inside the
  /// conversation lock: the work runs later and takes the lock itself.
  void onGroupChanged(String conversationId) {
    // Written down first: the app can be killed before the timer fires.
    unawaited(_ledger.markPending(conversationId));
    _timers[conversationId]?.cancel();
    _timers[conversationId] = Timer(_settleDelay(), () {
      _timers.remove(conversationId);
      unawaited(resendNow(conversationId));
    });
  }

  /// Re-sends [conversationId]'s unconfirmed messages. Never throws. Must not be
  /// called while holding that conversation's lock.
  Future<void> resendNow(String conversationId) async {
    if (await _run(conversationId, sweep: false)) {
      await _ledger.clearPending(conversationId);
    }
  }

  /// Collects every resend still owed and retries what is due on the backoff.
  /// Run it after a catchup, so receipts that were waiting are applied first.
  /// Never throws. Must not be called while holding a conversation lock.
  Future<void> sweep() async {
    final owed = await _ledger.pendingConversations();
    for (final id in owed) {
      await resendNow(id);
    }
    final others = [
      for (final c in _host.allConversations())
        if (!owed.contains(c.id)) c.id,
    ];
    for (final id in others) {
      await _run(id, sweep: true);
    }
  }

  /// True when it ran to completion, so nothing more is owed for this change.
  Future<bool> _run(String conversationId, {required bool sweep}) async {
    try {
      final sealed = await _host.runLocked(conversationId,
          () => _sealUnconfirmed(conversationId, sweep: sweep));
      // Outside the lock: a slow network must not hold up this chat's receive
      // path, and the ciphertexts no longer depend on the group's state.
      for (final payload in sealed) {
        try {
          await _host.submit(payload);
        } catch (e) {
          debugPrint('resend to ${payload.recipientDeviceId} failed: $e');
        }
      }
      return true;
    } catch (e) {
      debugPrint('resend for $conversationId failed: $e');
      return false;
    }
  }

  Future<List<SubmitMessagePayload>> _sealUnconfirmed(
    String conversationId, {
    required bool sweep,
  }) async {
    final convo = _host.conversation(conversationId);
    if (convo == null ||
        convo.blocked ||
        convo.kind != ConversationKind.oneToOne ||
        convo.cryptoMode != CryptoMode.mls) {
      return const [];
    }
    final candidates = await _unconfirmed(convo, sweep: sweep);
    if (candidates.isEmpty) return const [];
    final recipients = await _fanoutRecipients(convo);
    final now = _clock();
    final payloads = <SubmitMessagePayload>[];
    final attempted = <String>[];
    for (final message in candidates) {
      final body = buildResendWireBody(message, now: now);
      if (body == null) continue;
      attempted.add(message.clientMsgId!);
      final ciphertext = await _crypto.encrypt(
        groupId: conversationId,
        plaintext: utf8.encode(body),
      );
      final expiresAt = message.expiresAt;
      for (final r in recipients) {
        payloads.add(SubmitMessagePayload(
          conversationId: conversationId,
          envelopeType: wire.EnvelopeType.mlsApplication,
          recipientAccountId: r.accountId,
          recipientDeviceId: r.deviceId,
          ciphertext: ciphertext,
          ttlSeconds: expiresAt?.difference(now).inSeconds,
          pushKind: PushKind.silent,
        ));
      }
    }
    await _ledger.recordAttempts(attempted, now);
    return payloads;
  }

  /// This device's own sent messages with no end-to-end confirmation, oldest
  /// first, limited to the newest [_maxMessagesPerRun].
  Future<List<ChatMessage>> _unconfirmed(
    Conversation convo, {
    required bool sweep,
  }) async {
    final myDeviceId = await _host.selfDeviceId();
    final cutoff = _clock().subtract(_resendWindow);
    final eligible = <ChatMessage>[];
    for (final m in convo.messages) {
      if (!m.mine ||
          m.senderDeviceId != myDeviceId ||
          m.failed ||
          (m.outboxId ?? '').isNotEmpty ||
          m.serverTs.isBefore(cutoff)) {
        continue;
      }
      if (!await _attemptAllowed(m, sweep: sweep)) continue;
      if (m.deliveryStatus == MessageDeliveryStatus.sent ||
          (m.deliveryStatus == MessageDeliveryStatus.delivered &&
              await _transportReceipts.contains(m.envelopeId))) {
        eligible.add(m);
      }
    }
    eligible.sort((a, b) => a.serverTs.compareTo(b.serverTs));
    return eligible.length <= _maxMessagesPerRun
        ? eligible
        : eligible.sublist(eligible.length - _maxMessagesPerRun);
  }

  /// A group change retries at once while the message has budget left, because
  /// the new group is what the earlier copies could not reach. A sweep has no such
  /// evidence, so it waits out the backoff.
  Future<bool> _attemptAllowed(ChatMessage m, {required bool sweep}) async {
    final id = m.clientMsgId;
    if (id == null || id.isEmpty) return false;
    final attempt = await _ledger.attempt(id);
    if (!sweep) return attempt.count < _maxAttemptsPerMessage;
    if (attempt.count >= _sweepBackoff.length) return false;
    final lastAtMs = attempt.lastAtMs;
    final since = lastAtMs == null
        ? m.serverTs
        : DateTime.fromMillisecondsSinceEpoch(lastAtMs, isUtc: true);
    return _clock().difference(since) >= _sweepBackoff[attempt.count];
  }

  void dispose() {
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
  }
}
