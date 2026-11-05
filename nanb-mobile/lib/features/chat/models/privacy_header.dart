import 'dart:convert';

/// The sender's conversation-privacy flags, carried as a one-line JSON
/// header at the FRONT of every outgoing 1:1 wire body while either flag
/// is enabled: `{"_priv":{"s":0|1,"f":0|1}}\n<rest of body>` — same
/// prefix-header pattern as [ReplyRef].
///
/// `s` = the sender blocks screenshots of conversations they're in;
/// `f` = the sender blocks forwarding/copying of their messages.
///
/// Riding on every message (rather than only on a settings-change control)
/// makes propagation stateless and self-healing: a peer that missed the
/// toggle broadcast — new conversation, re-install, freshly linked device —
/// converges on the next message. The receiver stores the latest flags on
/// the conversation row (last-write-wins; 1:1 only, so the only writer is
/// the single peer). The companion `MessageControl.privacy` broadcast
/// handles the instant-toggle case, including toggling OFF (when both flags
/// are false no header is sent, so "off" can't be distinguished from an
/// old client by absence alone).
class PrivacyHeader {
  const PrivacyHeader({
    required this.blocksScreenshots,
    required this.blocksForwarding,
  });

  final bool blocksScreenshots;
  final bool blocksForwarding;

  /// The header line (including the trailing newline) to prepend to the body.
  String encodePrefix() =>
      '${jsonEncode({
            '_priv': {
              's': blocksScreenshots ? 1 : 0,
              'f': blocksForwarding ? 1 : 0,
            },
          })}\n';

  /// If [wireBody] begins with a `{"_priv":...}` header line, returns the
  /// parsed flags plus the remaining body after the newline. Otherwise null.
  /// Fast-rejects non-matching bodies.
  static (PrivacyHeader, String)? split(String wireBody) {
    if (!wireBody.startsWith('{"_priv"')) return null;
    final nl = wireBody.indexOf('\n');
    if (nl < 0) return null;
    try {
      final m = jsonDecode(wireBody.substring(0, nl)) as Map<String, dynamic>;
      final p = m['_priv'] as Map<String, dynamic>;
      final s = p['s'], f = p['f'];
      if (s is! int || f is! int) return null;
      return (
        PrivacyHeader(blocksScreenshots: s == 1, blocksForwarding: f == 1),
        wireBody.substring(nl + 1),
      );
    } catch (_) {
      return null;
    }
  }
}
