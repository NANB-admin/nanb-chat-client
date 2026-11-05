import 'dart:async';
import 'dart:io';

import 'package:web_socket_channel/io.dart';

import 'socks_proxy.dart';
import 'ws_transport.dart';

/// Native transport: `dart:io` WebSocket with the JWT in the `Authorization`
/// header (NOT a `?token=` query param — request URLs land verbatim in
/// server/proxy logs, which would leak live bearer tokens).
class IoWsTransport implements WsTransport {
  IoWsTransport({this.socksProxy});

  /// When set, the upgrade dials through a local SOCKS5 proxy (Tor) via a
  /// `customClient`, so the live connection routes identically to HTTP.
  final SocksProxyConfig? socksProxy;

  @override
  Future<WsTransportConnection> open({
    required Uri url,
    required String jwt,
  }) async {
    // Dart's Uri only knows default ports for http/https, so a `ws://`/`wss://`
    // URL parses with port 0. Over SOCKS that makes the proxy ask Tor to connect
    // to host:0 — which fails (verified on-device: an onion WS dialled `:0` and
    // the rendezvous FAILED, while `:80` SUCCEEDED). Default the port from the
    // scheme so the SOCKS CONNECT targets the right one. No-op on the direct
    // path (dart:io applies the same default), and explicit ports are preserved.
    if (url.port == 0) {
      url = url.replace(port: url.scheme == 'wss' ? 443 : 80);
    }
    // pingInterval makes dart:io send WS pings and force-close the socket
    // when the pong doesn't come back. Without it a half-open TCP connection
    // (emulator NAT idle drop, WiFi→cellular switch) looks connected forever:
    // the supervisor stays "connected", never reconnects, and real-time
    // delivery silently dies until the next app relaunch.
    // A SOCKS-patched HttpClient routes the upgrade through Tor; null leaves
    // dart:io's default direct client. socks5_proxy handles wss/TLS itself.
    // buildHttpClient can throw ArgumentError on a non-IP proxy host — let it
    // propagate so the supervisor's backoff loop surfaces it (same as a
    // handshake failure); nothing has been allocated to leak in that case.
    final proxy = socksProxy;
    final HttpClient? httpClient = proxy == null ? null : buildHttpClient(proxy);
    final ch = IOWebSocketChannel.connect(
      url,
      headers: {'Authorization': 'Bearer $jwt'},
      pingInterval: const Duration(seconds: 20),
      connectTimeout: const Duration(seconds: 10),
      customClient: httpClient,
    );
    try {
      // Surface handshake failures here so the supervisor's backoff loop
      // sees them — the bare constructor "succeeds" before the socket is up.
      await ch.ready;
    } catch (_) {
      unawaited(ch.sink.close().then((_) {}, onError: (_) {}));
      httpClient?.close(force: true);
      rethrow;
    }
    // dart:io NEVER closes a caller-supplied customClient and we keep no other
    // reference, so it is released via onClose whenever the channel is dropped —
    // otherwise every reconnect would leak an HttpClient + idle proxy connection.
    return WsTransportConnection(
      ch,
      onClose: httpClient == null ? null : () => httpClient.close(force: true),
    );
  }
}

/// Factory used by the conditional export in `ws_transport_factory.dart`.
WsTransport createWsTransport({SocksProxyConfig? socksProxy}) =>
    IoWsTransport(socksProxy: socksProxy);
