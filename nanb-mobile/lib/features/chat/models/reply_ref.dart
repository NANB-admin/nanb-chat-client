import 'dart:convert';

/// Reply/quote reference carried as a one-line JSON header prepended to a
/// message's wire body: `{"_reply":{"id","who","preview"}}\n<actual body>`.
///
/// The quoted sender name + a short preview are denormalized into the ref so
/// the recipient can render the quoted bar without fetching the original
/// (which may have aged out of its retention window).
class ReplyRef {
  const ReplyRef({
    required this.envelopeId,
    required this.sender,
    required this.preview,
  });

  final String envelopeId;
  final String sender;
  final String preview;

  /// The header line (including the trailing newline) to prepend to the body.
  String encodePrefix() =>
      '${jsonEncode({
            '_reply': {'id': envelopeId, 'who': sender, 'preview': preview},
          })}\n';

  /// If [wireBody] begins with a `{"_reply":...}` header line, returns the
  /// parsed ref plus the remaining body after the newline. Otherwise null
  /// (the body is a normal message). Fast-rejects non-matching bodies.
  static (ReplyRef, String)? split(String wireBody) {
    if (!wireBody.startsWith('{"_reply"')) return null;
    final nl = wireBody.indexOf('\n');
    if (nl < 0) return null;
    try {
      final m = jsonDecode(wireBody.substring(0, nl)) as Map<String, dynamic>;
      final r = m['_reply'] as Map<String, dynamic>;
      final id = r['id'], who = r['who'], preview = r['preview'];
      if (id is! String || who is! String || preview is! String) return null;
      return (
        ReplyRef(envelopeId: id, sender: who, preview: preview),
        wireBody.substring(nl + 1),
      );
    } catch (_) {
      return null;
    }
  }
}
