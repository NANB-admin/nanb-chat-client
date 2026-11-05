import 'package:web_socket_channel/web_socket_channel.dart';

/// An open WebSocket plus whatever must be released when it goes away.
class WsTransportConnection {
  const WsTransportConnection(this.channel, {this.onClose});

  final WebSocketChannel channel;

  /// Releases transport-owned resources (e.g. the SOCKS-patched HttpClient the
  /// native transport hands to the channel). Called whenever the channel is
  /// dropped; must be safe to call more than once.
  final void Function()? onClose;
}

/// How a [WsClientImpl] opens its socket. The protocol layer (acks, catch-up,
/// probe, reconnect signalling) is platform-neutral; only the way the upgrade
/// is made and authenticated differs:
///  - native: `dart:io`, JWT in the `Authorization` header, optional SOCKS;
///  - browser: no custom headers are possible, so a one-time ticket is fetched
///    over REST and passed in the query string.
abstract class WsTransport {
  /// Opens the socket at [url] (a `ws://`/`wss://` `/ws` URL) for the session
  /// identified by [jwt], and completes once the upgrade has succeeded.
  /// Handshake failures must surface as thrown errors, with nothing leaked.
  Future<WsTransportConnection> open({required Uri url, required String jwt});
}
