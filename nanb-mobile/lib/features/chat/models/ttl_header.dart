import 'dart:convert';

/// The sender's disappearing TTL (seconds), carried as a one-line JSON header
/// at the FRONT of every outgoing wire body: `{"_ttl":300}\n<rest of body>`
/// — the same prefix-header pattern as `PrivacyHeader` / `ReplyRef`.
///
/// This is what makes "disappears after X" *sender-controlled*: the recipient
/// expires its local copy at `sentAt + X` (the sender's choice at send time),
/// not on its own global retention setting. Without it, each side deleted on
/// its own setting, so a 5-minute message could linger for days on a recipient
/// who chose a longer default.
///
/// It's the OUTERMOST header — prepended last on send (in front of any privacy
/// / reply / forward headers) and split first on receive — so the remaining
/// body parses exactly as before for older clients that ignore it.
class TtlHeader {
  const TtlHeader(this.ttlSeconds);

  final int ttlSeconds;

  /// The header line (including the trailing newline) to prepend to the body.
  String encodePrefix() => '${jsonEncode({'_ttl': ttlSeconds})}\n';

  /// If [wireBody] begins with a `{"_ttl":...}` header line, returns the
  /// parsed TTL plus the remaining body after the newline. Otherwise null.
  /// Fast-rejects non-matching bodies.
  static (TtlHeader, String)? split(String wireBody) {
    if (!wireBody.startsWith('{"_ttl"')) return null;
    final nl = wireBody.indexOf('\n');
    if (nl < 0) return null;
    try {
      final m = jsonDecode(wireBody.substring(0, nl)) as Map<String, dynamic>;
      final t = m['_ttl'];
      if (t is! int || t <= 0) return null;
      return (TtlHeader(t), wireBody.substring(nl + 1));
    } catch (_) {
      return null;
    }
  }
}
