import 'dart:convert';

import '../../../../features/chat/models/chat_message.dart';
import '../../../../features/chat/models/link_preview.dart';
import '../../../../features/chat/models/message_kind.dart';
import '../models/web_row.dart';
import 'row_values.dart';

/// ChatMessage <-> `messages` row (same columns as the SQL table).
abstract final class MessageRowCodec {
  static WebRow encode(String conversationId, ChatMessage m) => {
        'envelope_id': m.envelopeId,
        'conversation_id': conversationId,
        'sender_device_id': m.senderDeviceId,
        'body': m.body,
        'server_ts': m.serverTs.toUtc().millisecondsSinceEpoch,
        'mine': RowValues.boolInt(m.mine),
        'outbox_id': m.outboxId,
        'client_msg_id': m.clientMsgId,
        'kind': m.kind.name,
        'media_id': m.mediaId,
        'media_key': m.mediaKey == null ? null : List<int>.from(m.mediaKey!),
        'media_sha256':
            m.mediaSha256 == null ? null : List<int>.from(m.mediaSha256!),
        'media_size': m.mediaSize,
        'media_mime': m.mediaMime,
        'media_filename': m.mediaFilename,
        'media_duration_ms': m.mediaDurationMs,
        'reply_to_envelope_id': m.replyToEnvelopeId,
        'reply_to_sender': m.replyToSender,
        'reply_to_preview': m.replyToPreview,
        'voice_waveform':
            m.voiceWaveform == null ? null : List<int>.from(m.voiceWaveform!),
        'failed': RowValues.boolInt(m.failed),
        'uploading': RowValues.boolInt(m.uploading),
        'pending_upload_key': m.pendingUploadKey == null
            ? null
            : List<int>.from(m.pendingUploadKey!),
        'delivery_status': m.deliveryStatus.index,
        'forwarded': RowValues.boolInt(m.forwarded),
        'expires_at': m.expiresAt?.toUtc().millisecondsSinceEpoch,
        'reactions': m.reactions.isEmpty ? null : jsonEncode(m.reactions),
        'link_preview': m.linkPreview?.encode(),
        'edited': RowValues.boolInt(m.edited),
        'delivered_at': m.deliveredAt?.toUtc().millisecondsSinceEpoch,
        'read_at': m.readAt?.toUtc().millisecondsSinceEpoch,
      };

  static ChatMessage decode(WebRow row) {
    final mediaKey = row['media_key'];
    final mediaSha = row['media_sha256'];
    final waveform = row['voice_waveform'];
    final pendingKey = row['pending_upload_key'];
    return ChatMessage(
      envelopeId: row['envelope_id'] as String,
      conversationId: row['conversation_id'] as String,
      senderDeviceId: row['sender_device_id'] as String,
      body: row['body'] as String,
      serverTs: RowValues.msToUtc(row['server_ts'])!,
      mine: RowValues.flag(row['mine']),
      outboxId: row['outbox_id'] as String?,
      clientMsgId: row['client_msg_id'] as String?,
      kind: MessageKind.fromName(row['kind'] as String?),
      mediaId: row['media_id'] as String?,
      mediaKey: mediaKey == null ? null : RowValues.intList(mediaKey),
      mediaSha256: mediaSha == null ? null : RowValues.intList(mediaSha),
      mediaSize: row['media_size'] as int?,
      mediaMime: row['media_mime'] as String?,
      mediaFilename: row['media_filename'] as String?,
      mediaDurationMs: row['media_duration_ms'] as int?,
      replyToEnvelopeId: row['reply_to_envelope_id'] as String?,
      replyToSender: row['reply_to_sender'] as String?,
      replyToPreview: row['reply_to_preview'] as String?,
      voiceWaveform: waveform == null ? null : RowValues.intList(waveform),
      failed: RowValues.flag(row['failed']),
      uploading: RowValues.flag(row['uploading']),
      pendingUploadKey:
          pendingKey == null ? null : RowValues.intList(pendingKey),
      deliveryStatus: MessageDeliveryStatus
          .values[(row['delivery_status'] as int?) ?? 0],
      forwarded: RowValues.flag(row['forwarded']),
      expiresAt: RowValues.msToUtc(row['expires_at']),
      reactions: _reactions(row['reactions'] as String?),
      linkPreview: LinkPreview.tryDecode(row['link_preview'] as String?),
      edited: RowValues.flag(row['edited']),
      deliveredAt: RowValues.msToUtc(row['delivered_at']),
      readAt: RowValues.msToUtc(row['read_at']),
    );
  }

  /// Tolerates null/garbage by returning an empty map (as the SQL impl does).
  static Map<String, String> _reactions(String? json) {
    if (json == null || json.isEmpty) return const {};
    try {
      final decoded = jsonDecode(json);
      if (decoded is! Map<String, Object?>) return const {};
      return decoded.map((k, v) => MapEntry(k, '$v'));
    } catch (_) {
      return const {};
    }
  }
}
