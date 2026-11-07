import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

import '../models/envelope.dart';
import 'connection_log.dart';
import 'socks_proxy.dart';
import 'ws_client.dart';
import 'ws_transport.dart';
import 'ws_transport_factory.dart';

/// Production WebSocket client. Excluded from coverage.
class WsClientImpl implements WsClient {
  WsClientImpl({required this.baseUrl, this.socksProxy, WsTransport? transport})
      : _transport = transport ?? createWsTransport(socksProxy: socksProxy);

  /// How the socket is opened and authenticated (native header vs browser
  /// ticket). Everything below this seam is platform-neutral protocol code.
  final WsTransport _transport;

  final String baseUrl;

  /// When set, the WebSocket upgrade dials through a local SOCKS5 proxy (Tor)
  /// via a `customClient`, so the live connection routes identically to the
  /// HTTP client. See `core/network/socks_proxy.dart`.
  final SocksProxyConfig? socksProxy;
  WebSocketChannel? _channel;
  // Releases transport-owned resources (e.g. the native SOCKS-patched
  // HttpClient, which dart:io never closes for us). Run whenever `_channel` is
  // nulled so a reconnect doesn't leak one per attempt.
  void Function()? _onTransportClose;
  final _controller = StreamController<Envelope>.broadcast();
  final _disconnects = StreamController<void>.broadcast();
  StreamSubscription<dynamic>? _sub;

  /// In-flight WS sends awaiting their server `send_ack`, keyed by client_ref.
  /// Completed by [_completeAck] when the matching frame arrives, or failed by

  /// In-flight catchup drains awaiting their `catchup_result`, keyed by
  /// client_ref. Separate from [_pendingAcks] because the payload differs and
  /// a drain is a READ — it is always safe to retry over HTTP.
  final Map<String, Completer<List<Envelope>>> _pendingCatchups = {};
  /// [_failPendingAcks] when the socket dies.
  final Map<String, Completer<({String envelopeId, DateTime serverTs})>>
      _pendingAcks = {};

  /// In-flight liveness [probe] awaiting its `pong`; null when none. Completed
  /// when the pong arrives, failed by [_failPendingProbe] when the socket dies.
  Completer<void>? _pendingProbe;

  @override
  Stream<Envelope> get envelopes => _controller.stream;

  @override
  Stream<void> get disconnects => _disconnects.stream;

  @override
  bool get isConnected => _channel != null;

  @override
  Future<void> connect(String jwt) async {
    if (_channel != null) return;
    // Auth is the transport's job: native sends the JWT in the Authorization
    // header (never a ?token= query param — URLs land in server/proxy logs),
    // a browser exchanges it for a one-time ticket first. Handshake failures
    // throw from here so the supervisor's backoff loop sees them.
    final url = Uri.parse('$baseUrl/ws');
    final conn = await _transport.open(url: url, jwt: jwt);
    final ch = conn.channel;
    _channel = ch;
    _onTransportClose = conn.onClose;
    ConnectionLog.instance.add('ws up');
    _sub = ch.stream.listen(
      (raw) {
        try {
          final json = jsonDecode(raw as String) as Map<String, dynamic>;
          // send_ack / send_error are the server's reply to one of OUR sends —
          // route them to the waiting completer instead of mis-parsing them as
          // an inbound envelope. Everything else is a server push (a delivered
          // message or a typing signal).
          final type = json['type'];
          if (type == 'send_ack' || type == 'send_error') {
            _completeAck(type as String, json);
            return;
          }
          // Reply to one of OUR catchup frames — route it to the waiting
          // completer. Must be handled BEFORE the envelope parse below, which
          // would otherwise try to read a result frame as a single envelope.
          if (type == 'catchup_result' || type == 'catchup_error') {
            _completeCatchup(type as String, json);
            return;
          }
          if (type == 'pong') {
            // Reply to a liveness [probe] — resolve it (socket is responsive).
            final p = _pendingProbe;
            _pendingProbe = null;
            if (p != null && !p.isCompleted) p.complete();
            return;
          }
          _controller.add(Envelope.fromJson(json));
        } catch (_) {
          // Drop malformed frames; production observability would log here.
        }
      },
      // The connection died underneath us (dart:io ping timeout, remote
      // close, network error). Null the channel so the next connect() isn't
      // a no-op, fail any in-flight sends so their callers don't hang, and
      // tell the supervisor via `disconnects` — the broadcast `envelopes`
      // controller never closes, so its onDone can't carry the signal. A
      // deliberate disconnect() cancels _sub first, so these handlers (and the
      // emit) don't run for intentional teardown.
      onError: (Object e) {
        // ignore: avoid_print
        print('NANBNET ws down (error): $e');
        ConnectionLog.instance.add('ws down error: ${e.runtimeType}');
        _onSocketDown();
        _disconnects.add(null);
      },
      onDone: () {
        // Close code distinguishes causes: a dart:io ping-timeout force-close
        // (no server close frame) reads as 1005/1006/null, a clean server close
        // as 1000/1001 — so a background test shows whether the socket is dying
        // to its own heartbeat vs the network/Tor genuinely dropping it.
        // ignore: avoid_print
        print('NANBNET ws down (done): closeCode=${ch.closeCode} '
            'reason=${ch.closeReason}');
        ConnectionLog.instance.add(
            'ws down closeCode=${ch.closeCode} reason=${ch.closeReason}');
        _onSocketDown();
        _disconnects.add(null);
      },
    );
  }

  void _onSocketDown() {
    _channel = null;
    _closeHttpClient();
    _failPendingAcks();
    _failPendingCatchups();
    _failPendingProbe();
  }

  /// Fails an in-flight [probe] when the socket dies, so it resolves false
  /// (→ reconnect) instead of waiting out its timeout.
  void _failPendingProbe() {
    final p = _pendingProbe;
    _pendingProbe = null;
    if (p != null && !p.isCompleted) {
      p.completeError(const WsDisconnectedException());
    }
  }

  /// Routes a `send_ack`/`send_error` frame to the completer registered under
  /// its `client_ref` (no-op for an unknown/late ref).
  void _completeAck(String type, Map<String, dynamic> json) {
    final ref = json['client_ref'] as String?;
    if (ref == null) return;
    final c = _pendingAcks.remove(ref);
    if (c == null || c.isCompleted) return;
    if (type == 'send_ack') {
      c.complete((
        envelopeId: json['envelope_id'] as String,
        serverTs: DateTime.parse(json['server_ts'] as String),
      ));
    } else {
      c.completeError(WsSendException(
        json['code'] as String?,
        (json['message'] as String?) ?? 'send failed',
      ));
    }
  }

  /// Routes a `catchup_result`/`catchup_error` frame to its waiting completer.
  void _completeCatchup(String type, Map<String, dynamic> json) {
    final ref = json['client_ref'] as String?;
    if (ref == null) return;
    final c = _pendingCatchups.remove(ref);
    if (c == null || c.isCompleted) return;
    if (type == 'catchup_result') {
      final list = json['envelopes'] as List? ?? const [];
      c.complete(list
          .cast<Map<String, dynamic>>()
          .map(Envelope.fromJson)
          .toList(growable: false));
    } else {
      c.completeError(WsSendException(
        json['code'] as String?,
        (json['message'] as String?) ?? 'catchup failed',
      ));
    }
  }

  /// Fails in-flight drains when the socket dies, so the caller falls back to
  /// HTTP instead of hanging on a reply that can never arrive.
  void _failPendingCatchups() {
    if (_pendingCatchups.isEmpty) return;
    final pending = _pendingCatchups.values.toList(growable: false);
    _pendingCatchups.clear();
    for (final c in pending) {
      if (!c.isCompleted) c.completeError(const WsDisconnectedException());
    }
  }

  /// Fails every in-flight send with [WsDisconnectedException] when the socket
  /// dies, so callers surface a failed send rather than hanging on a future
  /// whose ack can never arrive.
  void _failPendingAcks() {
    if (_pendingAcks.isEmpty) return;
    final pending = _pendingAcks.values.toList(growable: false);
    _pendingAcks.clear();
    for (final c in pending) {
      if (!c.isCompleted) c.completeError(const WsDisconnectedException());
    }
  }

  void _closeHttpClient() {
    final close = _onTransportClose;
    _onTransportClose = null;
    close?.call();
  }

  @override
  void sendEphemeral(Map<String, dynamic> frame) {
    final ch = _channel;
    if (ch == null) return;
    try {
      ch.sink.add(jsonEncode(frame));
    } catch (_) {
      // Socket mid-close — the signal is ephemeral, just drop it.
    }
  }

  @override
  bool sendAckFrame(List<String> envelopeIds) {
    final ch = _channel;
    if (ch == null) return false;
    try {
      ch.sink.add(jsonEncode({'type': 'ack', 'envelope_ids': envelopeIds}));
      return true;
    } catch (_) {
      return false; // sink mid-close → caller falls back to HTTP
    }
  }

  @override
  Future<({String envelopeId, DateTime serverTs})> sendAndAwaitAck(
    Map<String, dynamic> frame,
    String clientRef, {
    Duration timeout = const Duration(seconds: 10),
  }) {
    final ch = _channel;
    // No live socket → the frame can't leave; signal the caller to use HTTP.
    if (ch == null) throw const WsNotConnectedException();
    final completer = Completer<({String envelopeId, DateTime serverTs})>();
    _pendingAcks[clientRef] = completer;
    try {
      ch.sink.add(jsonEncode(frame));
    } catch (_) {
      // The sink rejected the write (mid-close): the frame never left, so HTTP
      // fallback is safe — same as a null channel.
      _pendingAcks.remove(clientRef);
      throw const WsNotConnectedException();
    }
    return completer.future.timeout(timeout, onTimeout: () {
      _pendingAcks.remove(clientRef);
      throw TimeoutException('ws send ack timed out', timeout);
    });
  }

  @override
  Future<List<Envelope>> catchupOverSocket(
    String clientRef, {
    int? limit,
    DateTime? since,
    Duration timeout = const Duration(seconds: 10),
  }) {
    final ch = _channel;
    // No live socket → nothing left; the caller drains over HTTP instead.
    if (ch == null) throw const WsNotConnectedException();
    final completer = Completer<List<Envelope>>();
    _pendingCatchups[clientRef] = completer;
    try {
      ch.sink.add(jsonEncode({
        'type': 'catchup',
        'client_ref': clientRef,
        'limit': ?limit,
        'since_server_ts': ?since?.toUtc().toIso8601String(),
      }));
    } catch (_) {
      _pendingCatchups.remove(clientRef);
      throw const WsNotConnectedException();
    }
    return completer.future.timeout(timeout, onTimeout: () {
      _pendingCatchups.remove(clientRef);
      throw TimeoutException('ws catchup timed out', timeout);
    });
  }

  @override
  Future<bool> probe({Duration timeout = const Duration(seconds: 5)}) async {
    final ch = _channel;
    if (ch == null) return false;
    // One probe in flight at a time; a concurrent caller rides the same wait.
    var completer = _pendingProbe;
    if (completer == null || completer.isCompleted) {
      completer = Completer<void>();
      _pendingProbe = completer;
      try {
        ch.sink.add(jsonEncode({'type': 'ping'}));
      } catch (_) {
        if (identical(_pendingProbe, completer)) _pendingProbe = null;
        return false; // sink mid-close → treat as not responsive
      }
    }
    try {
      await completer.future.timeout(timeout);
      ConnectionLog.instance.add('probe ok');
      return true; // pong arrived → socket is live, keep it
    } catch (_) {
      // Timeout OR the socket died first (WsDisconnectedException) → reconnect.
      ConnectionLog.instance.add('probe failed');
      if (identical(_pendingProbe, completer)) _pendingProbe = null;
      return false;
    }
  }

  @override
  Future<void> disconnect() async {
    if (_channel != null) ConnectionLog.instance.add('ws closed locally');
    await _sub?.cancel();
    _sub = null;
    await _channel?.sink.close();
    _channel = null;
    _closeHttpClient();
    _failPendingAcks();
    _failPendingCatchups();
    _failPendingProbe();
  }
}
