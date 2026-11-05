import 'message_kind.dart';

/// One queued outbound media upload. The optimistic outbox bubble already lives
/// under [outboxId] when this is pushed onto the upload stack — the worker fills
/// in the descriptor on success and runs the encrypt + submit step. Plaintext
/// [bytes] stay in memory until the worker either finishes (then cached under
/// the server envelope id) or fails (kept so a long-press retry can re-enqueue).
class PendingUpload {
  PendingUpload({
    required this.outboxId,
    required this.conversationId,
    required this.myDeviceId,
    required this.kind,
    required this.bytes,
    required this.mimeType,
    required this.bodyForUI,
    this.filename,
    this.waveform,
    this.durationMs,
    this.forwarded = false,
  });

  final String outboxId;
  final String conversationId;
  final String myDeviceId;
  final MessageKind kind;
  final List<int> bytes;
  final String mimeType;
  final String bodyForUI;
  final String? filename;
  final List<int>? waveform;
  final int? durationMs;

  /// True when this media message was forwarded from another conversation —
  /// the worker prepends the [ForwardMarker] header to the wire body.
  final bool forwarded;
}
