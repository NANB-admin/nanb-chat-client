import 'dart:async';
import 'dart:convert';

import '../../../core/models/envelope.dart' as wire;
import '../../../core/push/local_notifications.dart';
import '../../calls/models/call_signal.dart';
import '../media_pipeline.dart';
import '../models/chat_message.dart';
import '../models/client_msg_id_header.dart';
import '../models/conversation_kind.dart';
import '../models/forward_marker.dart';
import '../models/history_backfill.dart';
import '../models/message_control.dart';
import '../models/message_kind.dart';
import '../models/privacy_header.dart';
import '../models/reply_ref.dart';
import '../models/system_event.dart';
import '../models/ttl_header.dart';
import 'control_receiver.dart';
import 'control_sender.dart';
import 'notifier_service_host.dart';

/// The common post-decrypt path every inbound envelope funnels through after
/// its handler decrypts it: split the prefix headers (TTL → privacy → reply →
/// forward), route control / call-signal / history-backfill / group-info
/// payloads, else build the visible [ChatMessage], append it, bump unread,
/// ack the server, and fire a delivered receipt. ALWAYS invoked inside the
/// conversation's decrypt lock, so it mutates live state directly (never
/// re-takes the lock). Extracted from `ConversationsNotifier`.
class MessageAppender {
  MessageAppender({
    required NotifierServiceHost host,
    required ControlReceiver controlReceiver,
    required ControlSender controlSender,
    required void Function(String, CallSignal, String)? Function()
        callSignalHandler,
    required Future<void> Function(
            String convoId, String senderDeviceId, SystemEvent ev)
        applyGroupInfo,
    LocalNotifications? notifications,
    bool Function()? appInForeground,
    String? Function()? activeConversationId,
    bool Function(String envelopeId)? isCatchupEnvelope,
  })  : _host = host,
        _controlReceiver = controlReceiver,
        _controlSender = controlSender,
        _callSignalHandler = callSignalHandler,
        _applyGroupInfo = applyGroupInfo,
        _notifications = notifications,
        _appInForeground = appInForeground ?? (() => true),
        _activeConversationId = activeConversationId ?? (() => null),
        _isCatchupEnvelope = isCatchupEnvelope ?? ((_) => false);

  final NotifierServiceHost _host;
  final ControlReceiver _controlReceiver;
  final ControlSender _controlSender;
  final void Function(String, CallSignal, String)? Function() _callSignalHandler;
  final Future<void> Function(String, String, SystemEvent) _applyGroupInfo;

  /// Used to raise a local notification for an inbound message that arrived
  /// over the live socket while the app was backgrounded (see [append]). Null
  /// in tests that don't exercise notifications.
  final LocalNotifications? _notifications;

  /// Whether the app is currently in the foreground. When false, an inbound
  /// message needs its own notification — the FCM background isolate only runs
  /// when the socket is DOWN, but the socket is kept alive across backgrounding.
  final bool Function() _appInForeground;

  /// The conversation whose thread is currently OPEN (null if none). Together
  /// with [_appInForeground] this suppresses a notification ONLY for the chat
  /// the user is actively reading; every other case (background, chat list,
  /// another chat) still notifies.
  final String? Function() _activeConversationId;

  /// Whether [env]'s id belongs to the current (re)connect CATCHUP batch
  /// (backlog), as opposed to a genuinely live socket push. A backlog message
  /// was already covered by the FCM wakeup while the app was offline (or is
  /// unread the user is about to see on opening the app), so re-notifying it
  /// produces the "tapped the push → app reconnected → got pinged again"
  /// duplicate. Live pushes return false and still notify.
  final bool Function(String envelopeId) _isCatchupEnvelope;

  /// Process a decrypted [plaintext] for [env]: split headers, route control /
  /// call / backfill / group-info payloads, else append the visible message +
  /// ack + delivered receipt.
  Future<void> append({
    required wire.Envelope env,
    required String myDeviceId,
    required List<int> plaintext,
  }) async {
    final convoId = env.conversationId;

    // UTF-8 decode (sender encoded with utf8.encode). `allowMalformed: true`
    // means a corrupted byte renders as U+FFFD instead of throwing.
    final rawWireBody = utf8.decode(plaintext, allowMalformed: true);

    // Prefix headers ride at the FRONT of the body and are split off in
    // sender order — client-msg-id (outermost), then TTL, then privacy, then
    // reply, then forward marker.
    //
    // The client message id is a stable, sender-generated id used purely to
    // dedup a lost-ack auto-resend (see [ClientMsgIdHeader]); the dedup check
    // itself runs below, once we know this is a visible message.
    final cidSplit = ClientMsgIdHeader.split(rawWireBody);
    final String? clientMsgId = cidSplit?.$1.id;
    final afterCid = cidSplit?.$2 ?? rawWireBody;

    // The disappearing TTL is sender-controlled: we expire our local copy at
    // serverTs + the SENDER's TTL, not the recipient's own setting.
    final ttlSplit = TtlHeader.split(afterCid);
    final DateTime? msgExpiresAt = ttlSplit == null
        ? null
        : env.serverTs.toUtc().add(Duration(seconds: ttlSplit.$1.ttlSeconds));
    final afterTtl = ttlSplit?.$2 ?? afterCid;
    final privSplit = PrivacyHeader.split(afterTtl);
    final PrivacyHeader? privHeader = privSplit?.$1;
    final afterPriv = privSplit?.$2 ?? afterTtl;
    final replySplit = ReplyRef.split(afterPriv);
    final ReplyRef? replyRef = replySplit?.$1;
    final afterReply = replySplit?.$2 ?? afterPriv;
    final fwdRemainder = ForwardMarker.split(afterReply);
    final bool forwarded = fwdRemainder != null;
    final wireBody = fwdRemainder ?? afterReply;

    // Control payloads (unsend / receipts / reactions / …) ride inside the
    // encrypted body. They are never rendered — act on them and drop them.
    final control = MessageControl.tryDecode(wireBody);
    if (control != null) {
      await _controlReceiver.applyControl(
          convoId, control, env.senderDeviceId, myDeviceId);
      await _host.ack([env.envelopeId]);
      return;
    }

    // Call signaling (ring / SDP / ICE / hangup) rides inside the encrypted
    // body like a control message — never rendered. Hand it to the call layer.
    // Scheduled POST-LOCK (unawaited Future): the handler may send a reply,
    // which re-takes THIS conversation's lock — running it inline here (we're
    // inside the lock) would self-deadlock.
    final callSignal = CallSignal.tryDecode(wireBody);
    if (callSignal != null) {
      final handler = _callSignalHandler();
      if (handler != null) {
        unawaited(
            Future(() => handler(convoId, callSignal, env.senderDeviceId)));
      }
      await _host.ack([env.envelopeId]);
      return;
    }

    // History backfill: a batch of past messages a sibling device re-encrypted
    // to this freshly-linked device. Honour it ONLY from one of our own devices
    // (a peer must not be able to inject fabricated history).
    final backfill = HistoryBackfill.tryDecode(wireBody);
    if (backfill != null) {
      if (await _host.isMyDeviceWarm(env.senderDeviceId, myDeviceId)) {
        await _applyHistoryBackfill(backfill);
      }
      await _host.ack([env.envelopeId]);
      return;
    }

    // group_info is silent metadata, not a visible message: it carries the
    // group's name + full roster (which MLS doesn't transmit). Apply + drop.
    final sysEv = SystemEvent.tryDecode(wireBody);
    if (sysEv != null && sysEv.kind == SystemEventKind.groupInfo) {
      await _applyGroupInfo(convoId, env.senderDeviceId, sysEv);
      await _host.ack([env.envelopeId]);
      return;
    }

    // Detect _system JSON payloads and flag the message as a system event. The
    // body stays as the raw JSON; the UI parses it on display. Checked BEFORE
    // the media-descriptor branch (a system payload is never a descriptor).
    String body = wireBody;
    MessageKind kind = MessageKind.text;
    String? mediaId;
    List<int>? mediaKey;
    List<int>? mediaSha256;
    int? mediaSize;
    String? mediaMime;
    String? mediaFilename;
    List<int>? voiceWaveform;
    int? mediaDurationMs;
    if (SystemEvent.tryDecode(wireBody) != null) {
      kind = MessageKind.system;
    } else if (MediaDescriptor.looksLikeDescriptor(wireBody)) {
      try {
        final newlineIdx = wireBody.indexOf('\n');
        final descriptorJson =
            newlineIdx < 0 ? wireBody : wireBody.substring(0, newlineIdx);
        final caption =
            newlineIdx < 0 ? '' : wireBody.substring(newlineIdx + 1);
        final descriptor = MediaDescriptor.fromJson(descriptorJson);
        kind = descriptor.kind;
        body = caption;
        mediaId = descriptor.mediaId;
        mediaKey = descriptor.key;
        mediaSha256 = descriptor.sha256;
        mediaSize = descriptor.sizeBytes;
        mediaMime = descriptor.mimeType;
        mediaFilename = descriptor.filename;
        voiceWaveform = descriptor.waveform;
        mediaDurationMs = descriptor.durationMs;
      } catch (_) {
        // Malformed descriptor — fall back to text rendering.
      }
    }

    // Idempotency: a lost-ack auto-resend carries the SAME client message id as
    // the original. If we already stored a message from this sender with this
    // cid, this is that duplicate — ack it (so the server stops re-delivering)
    // and drop it, rather than rendering the message twice. Only visible
    // messages reach here; control/receipt/backfill payloads returned above and
    // are idempotent on their own.
    if (clientMsgId != null &&
        await _host.db.hasMessageWithClientId(
            convoId, env.senderDeviceId, clientMsgId)) {
      await _host.ack([env.envelopeId]);
      return;
    }

    // `mine` covers self-sync: a copy of our own send relayed to one of this
    // account's other devices arrives with a different senderDeviceId. Warm the
    // own-device cache if it's cold so a receive-only linked device still
    // recognises a sibling device as ours.
    final mine = await _host.isMyDeviceWarm(env.senderDeviceId, myDeviceId);
    final message = ChatMessage(
      envelopeId: env.envelopeId,
      conversationId: convoId,
      senderDeviceId: env.senderDeviceId,
      clientMsgId: clientMsgId,
      body: body,
      serverTs: env.serverTs,
      expiresAt: msgExpiresAt,
      mine: mine,
      kind: kind,
      mediaId: mediaId,
      mediaKey: mediaKey,
      mediaSha256: mediaSha256,
      mediaSize: mediaSize,
      mediaMime: mediaMime,
      mediaFilename: mediaFilename,
      voiceWaveform: voiceWaveform,
      mediaDurationMs: mediaDurationMs,
      replyToEnvelopeId: replyRef?.envelopeId,
      replyToSender: replyRef?.sender,
      replyToPreview: replyRef?.preview,
      forwarded: forwarded,
    );

    // Re-read the Conversation — it may have been mutated by a concurrent send
    // while decrypt was in flight. This is the lock-exclusive section.
    final existing = _host.conversation(convoId);
    if (existing == null) return; // convo was removed concurrently
    // The PEER's privacy header updates the conversation flags (1:1 only; skip
    // self-sync copies of our own sends — those carry OUR flags).
    final applyPriv = privHeader != null &&
        !mine &&
        existing.kind == ConversationKind.oneToOne;
    // A blocked contact's messages are still decrypted + stored (so the MLS
    // epoch / ratchet stays in sync) but arrive silently: no unread bump, no
    // un-archive, no delivered/read receipt.
    final blocked = existing.blocked;
    final updated = existing.copyWith(
      messages: [...existing.messages, message],
      // A self-synced copy of our OWN sent message (`mine`, from a sibling
      // device) is not something the user has yet to read.
      unreadCount: blocked || mine
          ? existing.unreadCount
          : existing.unreadCount + 1,
      archived: blocked ? existing.archived : false,
      peerBlocksScreenshots: applyPriv ? privHeader.blocksScreenshots : null,
      peerBlocksForwarding: applyPriv ? privHeader.blocksForwarding : null,
    );
    _host.setConversation(convoId, updated);
    // ONE commit for the pair, not two. On an encrypted store each commit pays
    // its own crypto + fsync, and this runs once per inbound envelope — so a
    // catchup drain was paying double for every message it appended.
    await _host.db.upsertConversationWithMessages(updated, [message]);
    await _host.maybeTrim(convoId);
    _host.notifyHost();

    await _host.ack([env.envelopeId]);

    // Send a "delivered" receipt back to the sender (1:1 visible content only).
    // Fired AFTER this lock releases — sendControl re-acquires the conversation
    // lock, so calling it inline would self-deadlock. Receipts are controls
    // (dropped on receipt), so they never trigger a receipt of their own.
    if (!message.mine &&
        !blocked &&
        updated.kind == ConversationKind.oneToOne &&
        kind != MessageKind.system) {
      final eid = env.envelopeId;
      unawaited(Future(() => _controlSender.sendControl(
            convoId,
            MessageControl.receipt(ReceiptKind.delivered, [eid]).encode(),
          )));
    }

    // Raise a notification for the inbound message. The main isolate has to do
    // this because the message arrived over the still-live socket — the FCM
    // background isolate only runs when the server FCM-pushes an OFFLINE device,
    // and the socket is kept alive across backgrounding, so FCM never fires.
    // Same id as the FCM path (conversationId.hashCode), so the socket + FCM
    // routes can never double-notify. Suppressed ONLY when the user is actively
    // viewing this exact thread (foreground + this conversation open) — they
    // already see the message; every other case (background, chat list, another
    // chat) notifies. Skipped for our own / muted / blocked / system messages.
    // Also skipped for a CATCHUP/backlog envelope: those were already covered by
    // the FCM wakeup while the app was offline (or are unread the user is about
    // to see on open), so notifying again is the "tapped the push, app
    // reconnected, got pinged a second time for the same message" duplicate.
    final notifications = _notifications;
    final activelyViewing =
        _appInForeground() && _activeConversationId() == convoId;
    if (notifications != null &&
        !message.mine &&
        !blocked &&
        !updated.muted &&
        kind != MessageKind.system &&
        !activelyViewing &&
        !_isCatchupEnvelope(env.envelopeId)) {
      unawaited(notifications.show(
        id: convoId.hashCode,
        title: 'New message',
        body: 'Open Chat to read',
        conversationId: convoId,
      ));
    }
  }

  /// Stores a chunk of backfilled history from a sibling device. Each message
  /// keeps its ORIGINAL envelope id (the PK, REPLACE-on-conflict), serverTs (so
  /// it sorts into place), and `mine` attribution. No unread bump, no receipts:
  /// history, not new mail. Called inside the conversation lock (operates on
  /// live state directly).
  Future<void> _applyHistoryBackfill(HistoryBackfill backfill) async {
    final convoId = backfill.conversationId;
    final convo = _host.conversation(convoId);
    if (convo == null) return;
    final existingIds = {for (final m in convo.messages) m.envelopeId};
    final additions = <ChatMessage>[];
    for (final b in backfill.messages) {
      if (existingIds.contains(b.envelopeId)) continue;
      existingIds.add(b.envelopeId);
      additions.add(ChatMessage(
        envelopeId: b.envelopeId,
        conversationId: convoId,
        senderDeviceId: b.senderDeviceId,
        body: b.body,
        serverTs:
            DateTime.fromMillisecondsSinceEpoch(b.serverTsMs, isUtc: true),
        mine: b.mine,
        kind: b.kind,
        mediaId: b.mediaId,
        mediaKey: b.mediaKey,
        mediaSha256: b.mediaSha256,
        mediaSize: b.mediaSize,
        mediaMime: b.mediaMime,
        mediaFilename: b.mediaFilename,
        voiceWaveform: b.voiceWaveform,
        mediaDurationMs: b.mediaDurationMs,
        replyToEnvelopeId: b.replyToEnvelopeId,
        replyToSender: b.replyToSender,
        replyToPreview: b.replyToPreview,
        forwarded: b.forwarded,
        expiresAt: b.expiresAtMs == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(b.expiresAtMs!, isUtc: true),
      ));
    }
    if (additions.isEmpty) return;
    await _host.db.upsertMessages(convoId, additions);
    final merged = [...convo.messages, ...additions]
      ..sort((a, b) => a.serverTs.compareTo(b.serverTs));
    _host.setConversation(convoId, convo.copyWith(messages: merged));
    _host.notifyHost();
  }
}
