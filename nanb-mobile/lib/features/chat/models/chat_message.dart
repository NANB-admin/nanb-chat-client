import 'package:flutter/foundation.dart';

import 'link_preview.dart';
import 'message_kind.dart';

/// Delivery state of an *outgoing* message, advanced by receipts the peer
/// sends back. `sent` = the server acked it; `delivered` = the peer's device
/// decrypted it; `read` = the peer opened the conversation. Monotonic: never
/// goes backwards (a late delivered receipt won't downgrade a read message).
/// Meaningless for inbound messages (always `sent`).
enum MessageDeliveryStatus { sent, delivered, read }

/// A single chat message held in the in-memory conversation store + the
/// SQLCipher-backed `messages` table.
@immutable
class ChatMessage {
  const ChatMessage({
    required this.envelopeId,
    required this.conversationId,
    required this.senderDeviceId,
    required this.body,
    required this.serverTs,
    required this.mine,
    this.outboxId,
    this.clientMsgId,
    this.kind = MessageKind.text,
    this.mediaId,
    this.mediaKey,
    this.mediaSha256,
    this.mediaSize,
    this.mediaMime,
    this.mediaFilename,
    this.voiceWaveform,
    this.mediaDurationMs,
    this.replyToEnvelopeId,
    this.replyToSender,
    this.replyToPreview,
    this.forwarded = false,
    this.failed = false,
    this.uploading = false,
    this.pendingUploadKey,
    this.deliveryStatus = MessageDeliveryStatus.sent,
    this.expiresAt,
    this.reactions = const {},
    this.linkPreview,
    this.edited = false,
    this.deliveredAt,
    this.readAt,
  });

  final String envelopeId;
  final String conversationId;
  final String senderDeviceId;

  /// For text messages: the message text. For media messages: the optional
  /// caption (may be empty).
  final String body;

  final DateTime serverTs;

  /// True for messages this device sent. Drives bubble alignment + status icons.
  final bool mine;

  /// Set on locally-composed messages before the server assigns an envelope_id.
  /// `null` once the message has round-tripped.
  final String? outboxId;

  /// Stable, sender-generated message id (the sender's `outboxId`), carried
  /// inside the E2EE body as a `_cid` wire header. Used purely for **idempotent
  /// delivery**: a lost-ack auto-resend reuses the same id, so the receiver
  /// dedups by (senderDeviceId, clientMsgId) and renders the message once
  /// instead of twice. Null on legacy rows + on our own optimistic copies (a
  /// sender never receives its own message, so it needs no dedup key).
  final String? clientMsgId;

  /// Discriminator for rendering. `text` for v1 chat content, `image` for
  /// v1.x media-pipeline messages.
  final MessageKind kind;

  /// Server-assigned media id (returned by `POST /media/init`). Required when
  /// `kind != text`.
  final String? mediaId;

  /// 32-byte AES key the sender used to encrypt the media bytes — wrapped
  /// inside the (ratchet-encrypted) message body so the server never sees
  /// it. Required when `kind != text`.
  final List<int>? mediaKey;

  /// SHA-256 of the *plaintext* media bytes, for integrity verification on
  /// download. Required when `kind != text`.
  final List<int>? mediaSha256;

  /// Plaintext byte size of the media. Used for UI display + as a sanity
  /// upper bound when downloading. Required when `kind != text`.
  final int? mediaSize;

  /// MIME type of the plaintext media (`image/jpeg`, `image/png`, etc.).
  /// Required when `kind != text`.
  final String? mediaMime;

  /// Original filename for `kind == MessageKind.file`. Null for other kinds.
  final String? mediaFilename;

  /// Captured-during-recording amplitude bars for `kind == MessageKind.voice`,
  /// each scaled to 0..255. Null for other kinds and for legacy voice notes
  /// recorded before the waveform feature shipped (renderer falls back to a
  /// static waveform in that case).
  final List<int>? voiceWaveform;

  /// Recorded duration in milliseconds for `kind == MessageKind.voice` —
  /// lets the bubble show the real length before the audio is ever loaded.
  /// Null for other kinds and legacy voice notes (label falls back to 0:00
  /// until first play).
  final int? mediaDurationMs;

  /// When this message is a reply, the envelope id of the quoted message
  /// (null for non-replies). [replyToSender] + [replyToPreview] are a
  /// denormalized snapshot so the quoted bar renders without fetching the
  /// original — they travel in the wire body and persist with the message.
  final String? replyToEnvelopeId;
  final String? replyToSender;
  final String? replyToPreview;

  bool get isReply => replyToEnvelopeId != null;

  /// True when this message was forwarded from another conversation. Rides
  /// the wire as a `ForwardMarker` header; the bubble renders a small
  /// "Forwarded" tag. Persisted.
  final bool forwarded;

  /// True when an outgoing message couldn't be delivered (server unreachable,
  /// crypto error, etc.). The bubble surfaces a retry affordance + the body
  /// stays the original text — we never mutate the body to track failure.
  final bool failed;

  /// True while an outgoing media message's upload is still in flight. The
  /// optimistic bubble renders a spinner during this window; once the upload
  /// finishes the descriptor fields populate and `uploading` flips to false.
  /// On app restart the boot-recovery sweep reads [pendingUploadKey], decrypts
  /// the staging file, and re-enqueues the upload — or, if the file's gone,
  /// flips the row to `failed=true`.
  final bool uploading;

  /// 32-byte AES key that encrypted the pending upload's plaintext bytes to
  /// disk. Present only on outbound media messages with `uploading=true` (and
  /// briefly on `failed=true` rows so retry can read back the staging file).
  /// Cleared once the server-acked row replaces the outbox entry. The
  /// SQLCipher-encrypted DB keeps this key opaque to anyone without the
  /// device's app sandbox.
  final List<int>? pendingUploadKey;

  /// Delivery state for outgoing messages, advanced by peer receipts.
  final MessageDeliveryStatus deliveryStatus;

  /// Absolute time this message disappears. Carried from the SENDER via the
  /// `_ttl` wire header (= sentAt + the sender's retention setting), so both
  /// sides delete on the sender's timer rather than the recipient's own
  /// setting. Null for legacy messages sent before per-message TTL shipped —
  /// those fall back to the global disappearing sweep.
  final DateTime? expiresAt;

  /// Emoji reactions on this message, keyed by the **reactor's account id** →
  /// the single emoji they reacted with (one reaction per person; reacting
  /// again replaces, reacting with the same emoji clears). Empty when none.
  /// Mutated by reaction control messages and persisted with the row.
  final Map<String, String> reactions;

  /// The card for a link in [body] (title / description / thumbnail), attached
  /// after the fact by a `link_preview` control from the author. Null when the
  /// message has no link, the author's fetch failed, or it hasn't arrived yet.
  final LinkPreview? linkPreview;

  /// True once the author has edited the text after sending.
  final bool edited;

  /// When the recipient's device confirmed delivery / the recipient read it, as
  /// seen by this device (the moment the receipt arrived). Null until then, and
  /// [readAt] stays null if the recipient has read receipts turned off.
  final DateTime? deliveredAt;
  final DateTime? readAt;

  ChatMessage copyWith({
    String? envelopeId,
    String? body,
    DateTime? serverTs,
    String? outboxId,
    String? clientMsgId,
    bool? failed,
    bool? uploading,
    String? mediaId,
    List<int>? mediaKey,
    List<int>? mediaSha256,
    int? mediaSize,
    String? mediaMime,
    String? mediaFilename,
    List<int>? voiceWaveform,
    int? mediaDurationMs,
    List<int>? pendingUploadKey,
    bool clearPendingUploadKey = false,
    MessageDeliveryStatus? deliveryStatus,
    DateTime? expiresAt,
    Map<String, String>? reactions,
    LinkPreview? linkPreview,
    bool clearLinkPreview = false,
    bool? edited,
    DateTime? deliveredAt,
    DateTime? readAt,
  }) {
    return ChatMessage(
      envelopeId: envelopeId ?? this.envelopeId,
      conversationId: conversationId,
      senderDeviceId: senderDeviceId,
      body: body ?? this.body,
      serverTs: serverTs ?? this.serverTs,
      mine: mine,
      outboxId: outboxId ?? this.outboxId,
      clientMsgId: clientMsgId ?? this.clientMsgId,
      kind: kind,
      mediaId: mediaId ?? this.mediaId,
      mediaKey: mediaKey ?? this.mediaKey,
      mediaSha256: mediaSha256 ?? this.mediaSha256,
      mediaSize: mediaSize ?? this.mediaSize,
      mediaMime: mediaMime ?? this.mediaMime,
      mediaFilename: mediaFilename ?? this.mediaFilename,
      voiceWaveform: voiceWaveform ?? this.voiceWaveform,
      mediaDurationMs: mediaDurationMs ?? this.mediaDurationMs,
      replyToEnvelopeId: replyToEnvelopeId,
      replyToSender: replyToSender,
      replyToPreview: replyToPreview,
      forwarded: forwarded,
      failed: failed ?? this.failed,
      uploading: uploading ?? this.uploading,
      pendingUploadKey: clearPendingUploadKey
          ? null
          : (pendingUploadKey ?? this.pendingUploadKey),
      deliveryStatus: deliveryStatus ?? this.deliveryStatus,
      expiresAt: expiresAt ?? this.expiresAt,
      reactions: reactions ?? this.reactions,
      linkPreview:
          clearLinkPreview ? null : (linkPreview ?? this.linkPreview),
      edited: edited ?? this.edited,
      deliveredAt: deliveredAt ?? this.deliveredAt,
      readAt: readAt ?? this.readAt,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ChatMessage &&
          envelopeId == other.envelopeId &&
          conversationId == other.conversationId &&
          senderDeviceId == other.senderDeviceId &&
          body == other.body &&
          serverTs == other.serverTs &&
          mine == other.mine &&
          outboxId == other.outboxId &&
          clientMsgId == other.clientMsgId &&
          kind == other.kind &&
          mediaId == other.mediaId &&
          listEquals(mediaKey, other.mediaKey) &&
          listEquals(mediaSha256, other.mediaSha256) &&
          mediaSize == other.mediaSize &&
          mediaMime == other.mediaMime &&
          mediaFilename == other.mediaFilename &&
          listEquals(voiceWaveform, other.voiceWaveform) &&
          mediaDurationMs == other.mediaDurationMs &&
          replyToEnvelopeId == other.replyToEnvelopeId &&
          replyToSender == other.replyToSender &&
          replyToPreview == other.replyToPreview &&
          forwarded == other.forwarded &&
          failed == other.failed &&
          uploading == other.uploading &&
          listEquals(pendingUploadKey, other.pendingUploadKey) &&
          deliveryStatus == other.deliveryStatus &&
          expiresAt == other.expiresAt &&
          mapEquals(reactions, other.reactions) &&
          linkPreview == other.linkPreview &&
          edited == other.edited &&
          deliveredAt == other.deliveredAt &&
          readAt == other.readAt;

  @override
  int get hashCode => Object.hash(
        envelopeId,
        conversationId,
        senderDeviceId,
        body,
        serverTs,
        mine,
        outboxId,
        kind,
        mediaId,
        mediaKey == null ? 0 : Object.hashAll(mediaKey!),
        mediaSha256 == null ? 0 : Object.hashAll(mediaSha256!),
        mediaSize,
        mediaMime,
        mediaFilename,
        voiceWaveform == null ? 0 : Object.hashAll(voiceWaveform!),
        mediaDurationMs,
        // Combined into one slot — Object.hash caps at 20 positional args.
        Object.hash(replyToEnvelopeId, replyToSender, replyToPreview, forwarded,
            clientMsgId, linkPreview, edited, deliveredAt, readAt),
        failed,
        uploading,
        // Combined into one slot — Object.hash caps at 20 positional args.
        Object.hash(
          pendingUploadKey == null ? 0 : Object.hashAll(pendingUploadKey!),
          deliveryStatus,
          expiresAt,
          // Order-independent so two equal maps hash alike.
          reactions.isEmpty
              ? 0
              : Object.hashAllUnordered(
                  reactions.entries.map((e) => '${e.key}=${e.value}')),
        ),
      );
}
