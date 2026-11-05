import 'dart:convert';

/// A stable, sender-generated message id (the sender's `outboxId`) carried as a
/// one-line JSON header at the FRONT of the wire body: `{"_cid":"outbox-…"}\n`
/// — the same prefix-header pattern as `TtlHeader` / `PrivacyHeader`. It rides
/// INSIDE the E2EE body, so the server never sees it (sealed-sender safe, unlike
/// a server-side idempotency key which would need the server to correlate the
/// sender across resends).
///
/// Purpose: **idempotent delivery**. A send whose ack was lost is auto-resent on
/// the next reconnect; the resend re-encrypts but reuses the SAME `outboxId`, so
/// both copies carry the same `_cid`. The receiver dedups by
/// (senderDeviceId, cid) so the message renders exactly once instead of twice.
///
/// It is the OUTERMOST header — prepended last on send (in front of the TTL /
/// privacy / reply / forward headers) and split first on receive — so the
/// remaining body parses exactly as before once it's stripped.
class ClientMsgIdHeader {
  const ClientMsgIdHeader(this.id);

  final String id;

  /// The header line (including the trailing newline) to prepend to the body.
  String encodePrefix() => '${jsonEncode({'_cid': id})}\n';

  /// If [wireBody] begins with a `{"_cid":"…"}` header line, returns the id plus
  /// the remaining body after the newline. Otherwise null. Fast-rejects
  /// non-matching bodies.
  static (ClientMsgIdHeader, String)? split(String wireBody) {
    if (!wireBody.startsWith('{"_cid"')) return null;
    final nl = wireBody.indexOf('\n');
    if (nl < 0) return null;
    try {
      final m = jsonDecode(wireBody.substring(0, nl)) as Map<String, dynamic>;
      final id = m['_cid'];
      if (id is! String || id.isEmpty) return null;
      return (ClientMsgIdHeader(id), wireBody.substring(nl + 1));
    } catch (_) {
      return null;
    }
  }
}
