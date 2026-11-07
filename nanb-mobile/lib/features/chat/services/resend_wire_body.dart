import '../media_pipeline.dart';
import '../models/chat_message.dart';
import '../models/client_msg_id_header.dart';
import '../models/forward_marker.dart';
import '../models/message_kind.dart';
import '../models/reply_ref.dart';
import '../models/ttl_header.dart';

/// Rebuilds the wire body of a message this device already sent, from its stored
/// row, with the headers in the same order the original send used (client id,
/// TTL, reply, forward). Used to re-encrypt it under a new MLS group.
///
/// Returns null when it must not be re-sent: no client id (the receiver could not
/// dedup it, so it might render twice), a system message, an expired disappearing
/// message, or media whose descriptor fields were not stored.
String? buildResendWireBody(ChatMessage message, {required DateTime now}) {
  final clientMsgId = message.clientMsgId;
  if (clientMsgId == null || clientMsgId.isEmpty) return null;
  var body = _content(message);
  if (body == null) return null;
  if (message.forwarded) body = '${ForwardMarker.prefix}$body';
  final replyId = message.replyToEnvelopeId;
  if (replyId != null) {
    body = ReplyRef(
          envelopeId: replyId,
          sender: message.replyToSender ?? '',
          preview: message.replyToPreview ?? '',
        ).encodePrefix() +
        body;
  }
  final expiresAt = message.expiresAt;
  if (expiresAt != null) {
    final remaining = expiresAt.difference(now).inSeconds;
    if (remaining <= 0) return null;
    body = TtlHeader(remaining).encodePrefix() + body;
  }
  return ClientMsgIdHeader(clientMsgId).encodePrefix() + body;
}

String? _content(ChatMessage message) {
  switch (message.kind) {
    case MessageKind.system:
      return null;
    case MessageKind.text:
      return message.body;
    case MessageKind.image:
    case MessageKind.video:
    case MessageKind.voice:
    case MessageKind.file:
      return _mediaContent(message);
  }
}

String? _mediaContent(ChatMessage message) {
  final mediaId = message.mediaId;
  final key = message.mediaKey;
  final sha256 = message.mediaSha256;
  final size = message.mediaSize;
  final mime = message.mediaMime;
  if (mediaId == null ||
      key == null ||
      sha256 == null ||
      size == null ||
      mime == null) {
    return null;
  }
  final descriptor = MediaDescriptor(
    kind: message.kind,
    mediaId: mediaId,
    key: key,
    sha256: sha256,
    sizeBytes: size,
    mimeType: mime,
    filename: message.mediaFilename,
    waveform: message.voiceWaveform,
    durationMs: message.mediaDurationMs,
  ).toJson();
  // Same layout as the upload path: a caption rides after the descriptor line.
  return message.kind == MessageKind.voice || message.body.isEmpty
      ? descriptor
      : '$descriptor\n${message.body}';
}
