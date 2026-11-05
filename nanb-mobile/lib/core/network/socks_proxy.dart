import 'dart:io';

import 'package:socks5_proxy/socks_client.dart';

/// A SOCKS5 proxy endpoint the app routes its traffic through — in practice
/// the local SOCKS port a Tor client exposes (Orbot's default `127.0.0.1:9050`).
///
/// This is what lets NANb *itself* speak Tor: rather than depending on the OS
/// to transparently capture `.onion` traffic, the HTTP client and the
/// WebSocket dial the proxy and let it (Tor) do the onion routing + remote DNS.
class SocksProxyConfig {
  const SocksProxyConfig({required this.host, required this.port});

  /// Proxy host. Must be a literal IP (e.g. `127.0.0.1`) — the SOCKS handshake
  /// needs an [InternetAddress] and we resolve it synchronously. Tor's local
  /// proxy is always loopback, so this is not a real limitation.
  final String host;

  /// Proxy port (Tor/Orbot SOCKS default is 9050; Tor Browser uses 9150).
  final int port;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SocksProxyConfig && other.host == host && other.port == port;

  @override
  int get hashCode => Object.hash(host, port);

  @override
  String toString() => 'SocksProxyConfig($host:$port)';
}

/// Builds an [HttpClient] whose connections are tunnelled through [proxy] when
/// it is non-null, or a plain direct client when it is null.
///
/// The same builder feeds both transports so they route identically:
///   - Dio HTTP  — via `IOHttpClientAdapter(createHttpClient: …)`.
///   - WebSocket — via `IOWebSocketChannel.connect(…, customClient: …)`.
///
/// `socks5_proxy` overrides the client's `connectionFactory`; it sends the
/// destination host to the proxy as a domain name (SOCKS5 remote DNS), so
/// `.onion` addresses resolve inside Tor, and it layers TLS itself for
/// `https`/`wss` targets.
HttpClient buildHttpClient(SocksProxyConfig? proxy) {
  final client = HttpClient();
  if (proxy == null) return client;
  final address = InternetAddress.tryParse(proxy.host);
  if (address == null) {
    // Non-literal host — we can't resolve synchronously here. Fail loud rather
    // than silently routing in the clear. (Tor's proxy is loopback; callers
    // should pass an IP like 127.0.0.1.)
    client.close(force: true);
    throw ArgumentError.value(
      proxy.host,
      'proxy.host',
      'SOCKS proxy host must be a literal IP (e.g. 127.0.0.1)',
    );
  }
  SocksTCPClient.assignToHttpClient(client, [ProxySettings(address, proxy.port)]);
  return client;
}
