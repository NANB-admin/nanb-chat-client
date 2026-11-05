import 'dart:async';

import 'package:dio/dio.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'ws_transport.dart';

/// Opens a [WebSocketChannel] for a fully-formed URL. Injected so the ticket
/// flow can be tested without a real socket.
typedef WsChannelOpener = WebSocketChannel Function(Uri url);

/// Browser transport. A browser cannot set an `Authorization` header on a
/// WebSocket handshake, and a long-lived bearer token in the URL would leak
/// into logs, so the session is first exchanged — over an authenticated REST
/// call — for a single-use, ~30 s ticket (`POST /ws/ticket`) that is passed in
/// the query string. A leaked ticket URL is useless: it is spent on first use.
class TicketWsTransport implements WsTransport {
  /// [dio] is injected (never constructed here) so the only place a direct,
  /// non-SOCKS client is built is the web-only factory — see the architecture
  /// guard `no_clearnet_bypass_test.dart`.
  TicketWsTransport({required WsChannelOpener openChannel, required Dio dio})
      : _openChannel = openChannel,
        _dio = dio;

  final WsChannelOpener _openChannel;
  final Dio _dio;

  @override
  Future<WsTransportConnection> open({
    required Uri url,
    required String jwt,
  }) async {
    final ticket = await _fetchTicket(url, jwt);
    final ticketUrl = url.replace(queryParameters: {'ticket': ticket});
    final ch = _openChannel(ticketUrl);
    try {
      await ch.ready;
    } catch (_) {
      // Handshake failed: close quietly and let the supervisor back off.
      unawaited(ch.sink.close().then((_) {}, onError: (_) {}));
      rethrow;
    }
    return WsTransportConnection(ch);
  }

  Future<String> _fetchTicket(Uri wsUrl, String jwt) async {
    // Built explicitly: Uri.replace(query: '') would leave a dangling '?'.
    final restUrl = Uri(
      scheme: wsUrl.scheme == 'wss' ? 'https' : 'http',
      host: wsUrl.host,
      port: wsUrl.hasPort ? wsUrl.port : null,
      path: '/ws/ticket',
    );
    final res = await _dio.postUri<Map<String, dynamic>>(
      restUrl,
      options: Options(
        headers: {'Authorization': 'Bearer $jwt'},
        responseType: ResponseType.json,
        sendTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 10),
      ),
    );
    final ticket = res.data?['ticket'];
    if (ticket is! String || ticket.isEmpty) {
      throw const FormatException('ws ticket response missing "ticket"');
    }
    return ticket;
  }
}
