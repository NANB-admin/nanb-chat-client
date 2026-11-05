/// Forwarded-message marker carried as a one-line JSON header on the wire
/// body: `{"_fwd":1}\n<actual body>` — same prefix-header pattern as
/// [ReplyRef]. The receiver splits it off and renders a small "Forwarded"
/// tag on the bubble.
///
/// Stacking order on the wire (outermost first): privacy header → reply
/// header → forward marker → body. A forwarded message never carries a
/// reply header in practice (the forward UI doesn't quote), but the split
/// order in `_appendDecryptedMessage` tolerates both.
class ForwardMarker {
  ForwardMarker._();

  /// The header line (including the trailing newline) to prepend to the body.
  static const String prefix = '{"_fwd":1}\n';

  /// If [wireBody] begins with the forward marker, returns the remaining
  /// body after the newline. Otherwise null (a normal message).
  static String? split(String wireBody) {
    if (!wireBody.startsWith(prefix)) return null;
    return wireBody.substring(prefix.length);
  }
}
