/// How often a sent message has been re-sent, and when it last was.
class ResendAttempt {
  const ResendAttempt({this.count = 0, this.lastAtMs});

  final int count;

  /// Milliseconds since epoch; null if it has never been re-sent.
  final int? lastAtMs;
}
