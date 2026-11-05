import 'package:dio/dio.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'socks_proxy.dart';
import 'ws_ticket_transport.dart';
import 'ws_transport.dart';

/// Factory used by the conditional export in `ws_transport_factory.dart`.
/// SOCKS (Tor) is impossible in a browser, so [socksProxy] is ignored and the
/// ticket request goes direct. This file is compiled ONLY for web (conditional
/// export), which is why a bare Dio is permitted here.
WsTransport createWsTransport({SocksProxyConfig? socksProxy}) =>
    TicketWsTransport(openChannel: WebSocketChannel.connect, dio: Dio());
