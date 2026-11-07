/// Marks a message as "view once": the recipient can open it a single time,
/// after which its content is gone from all of their devices. Rides between
/// the privacy header and the reply header, so the receiver splits it in that
/// order (see `MessageAppender.append`).
class ViewOnceHeader {
  const ViewOnceHeader._();

  static const String prefix = '{"_once":1}\n';

  /// How long an unopened view-once message is kept before it disappears.
  static const Duration unopenedLifetime = Duration(days: 14);

  /// The body after the marker, or null when [body] isn't view once.
  static String? split(String body) =>
      body.startsWith(prefix) ? body.substring(prefix.length) : null;

  /// When a view-once message sent at [serverTs] goes, whichever comes first of
  /// its unopened lifetime and the chat's own disappearing time [ttlExpiry].
  static DateTime expiry(DateTime serverTs, DateTime? ttlExpiry) {
    final unopened = serverTs.toUtc().add(unopenedLifetime);
    if (ttlExpiry == null) return unopened;
    return ttlExpiry.isBefore(unopened) ? ttlExpiry : unopened;
  }
}
