import '../models/envelope.dart';

/// Thrown by [WsClient.sendAndAwaitAck] when the frame could NOT be put on the
/// wire (no live socket, or the sink rejected it). The frame never left, so the
/// caller may safely fall back to another transport (HTTP POST) without risking
/// double-delivery.
class WsNotConnectedException implements Exception {
  const WsNotConnectedException();
  @override
  String toString() => 'WsNotConnectedException';
}

/// Thrown when the server answered a send frame with a `send_error` frame
/// (e.g. the recipient device is gone). The frame DID reach the server, so the
/// caller must NOT silently re-send over another transport.
class WsSendException implements Exception {
  const WsSendException(this.code, this.message);
  final String? code;
  final String message;
  @override
  String toString() => 'WsSendException($code: $message)';
}

/// Thrown to a pending send when the socket dies before its ack arrives. The
/// frame MAY have landed server-side, so — like a lost HTTP response — the
/// caller surfaces it as a failed send for manual retry rather than auto
/// re-sending (which could double-deliver).
class WsDisconnectedException implements Exception {
  const WsDisconnectedException();
  @override
  String toString() => 'WsDisconnectedException';
}

/// Real-time push channel from nanb-server. Production wires
/// `web_socket_channel`; tests inject a fake.
abstract class WsClient {
  /// Stream of envelopes pushed by the server. Multi-subscription is up to the
  /// implementation — the production impl uses `Stream.broadcast`. This stream
  /// outlives individual connections (it does NOT emit done when the socket
  /// drops); consumers keep one subscription across reconnects.
  Stream<Envelope> get envelopes;

  /// Emits one event each time an established connection dies underneath us
  /// (remote close, network death, ping timeout). A deliberate [disconnect]
  /// does NOT emit. The reconnect supervisor listens to this to schedule
  /// reconnects — `envelopes` can't carry the signal because its broadcast
  /// stream never closes.
  Stream<void> get disconnects;

  /// Sends an ephemeral JSON frame UP the socket (e.g. a typing signal). The
  /// server relays it to the recipient without persisting. No-op when not
  /// connected; fire-and-forget (never throws).
  void sendEphemeral(Map<String, dynamic> frame);

  /// Marks received [envelopeIds] consumed over the socket instead of a fresh
  /// HTTP POST. Fire-and-forget: an ack is idempotent and a lost one just
  /// redelivers on the next catchup. Returns true if the frame was put on the
  /// wire; false when no live socket — the caller then falls back to HTTP.
  /// Never throws.
  bool sendAckFrame(List<String> envelopeIds);

  /// Whether a live socket is currently up (so [sendAndAwaitAck] can be tried).
  bool get isConnected;

  /// Sends a `send` [frame] UP the socket and resolves when the server returns
  /// the matching `send_ack` (correlated by [clientRef]) — the WhatsApp-style
  /// path that reuses the already-warm connection instead of a fresh HTTPS POST.
  ///
  /// Resolves with the server-assigned `(envelopeId, serverTs)`. Throws
  /// [WsNotConnectedException] if the frame couldn't be sent (safe to retry on
  /// HTTP), [WsSendException] on a `send_error` reply, [WsDisconnectedException]
  /// if the socket drops first, or [TimeoutException] if no ack arrives within
  /// [timeout] — the last three mean the frame may have landed, so the caller
  /// surfaces a failed send rather than auto-resending.
  /// Drains the receive backlog over the live socket instead of a fresh
  /// `POST /messages/catchup`, resolving with the returned envelopes.
  ///
  /// The HTTP call runs at the worst possible moment — right after connect,
  /// concurrently with the rest of the connect fan-out — so it can't reuse a
  /// pooled connection and pays a full DNS+TCP+TLS setup. Measured on-device
  /// 2026-08-22 that one request cost 644-957ms while the server answered it in
  /// under 10ms: more than half of the entire catchup. Over the already-warm
  /// socket it costs neither.
  ///
  /// Throws [WsNotConnectedException] when there's no live socket (the caller
  /// falls back to HTTP — nothing was consumed, so that is always safe),
  /// [WsSendException] on a `catchup_error` reply, [WsDisconnectedException] if
  /// the socket drops first, or [TimeoutException]. A drain is a pure READ, so
  /// unlike a send it is safe to retry over HTTP after ANY of these.
  Future<List<Envelope>> catchupOverSocket(
    String clientRef, {
    int? limit,
    Duration timeout = const Duration(seconds: 10),
  });

  Future<({String envelopeId, DateTime serverTs})> sendAndAwaitAck(
    Map<String, dynamic> frame,
    String clientRef, {
    Duration timeout,
  });

  /// Liveness probe: sends an app-level `ping` and resolves true when the
  /// server's `pong` returns within [timeout]. Resolves false on timeout or when
  /// there's no live socket. Used on app-resume to confirm a (possibly stale)
  /// socket is actually responsive BEFORE paying for a reconnect — which is
  /// several seconds over Tor — so a socket that survived the background is kept.
  Future<bool> probe({Duration timeout});

  /// Connect using the given JWT for authentication. Idempotent — calling on an
  /// already-connected client is a no-op.
  Future<void> connect(String jwt);

  /// Close the connection deliberately. Does not emit on [disconnects].
  Future<void> disconnect();
}
