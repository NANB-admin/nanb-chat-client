/// One piece of evidence attached to a user report: a recent message FROM the
/// reported user, decrypted on this device and forwarded for moderation review.
/// The server otherwise never sees plaintext — these are included only because
/// the reporter chose to report them.
class ReportedMessage {
  const ReportedMessage({
    required this.sender,
    required this.body,
    required this.kind,
    this.sentAt,
  });

  /// Display label of the reported user (the peer's @handle).
  final String sender;

  /// Text, or the caption for a media message ("" when there is no caption).
  final String body;

  /// Message kind name (`text`, `image`, `voice`, `video`, `file`).
  final String kind;

  /// When the message was received, best-effort.
  final DateTime? sentAt;

  Map<String, dynamic> toJson() => {
        'sender': sender,
        'body': body,
        'kind': kind,
        if (sentAt != null) 'sent_at': sentAt!.toUtc().toIso8601String(),
      };
}
