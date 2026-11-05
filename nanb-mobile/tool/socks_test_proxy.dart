// A tiny logging SOCKS5 proxy for live-testing the app's SOCKS routing.
//
// It accepts SOCKS5 connections, prints every CONNECT target, then forwards
// the bytes to that target. Because it LOGS each connection, you can watch the
// app's traffic flow through it — proving the HTTP client and the WebSocket
// actually route through SOCKS (not silently bypassing it).
//
// It is NOT Tor — it adds no anonymity. It's a verification harness for the
// app-side SOCKS wiring (core/network/socks_proxy.dart). The real-Tor stages
// of the test plan use Orbot instead (see docs/socks-live-test.md).
//
// Run from nanb-mobile/ (so the socks5_proxy dep resolves):
//   dart run tool/socks_test_proxy.dart          # listens on 0.0.0.0:1080
//   dart run tool/socks_test_proxy.dart 9050      # custom port
//
// Emulator reaches a host-run proxy at 10.0.2.2:<port>; a real device on the
// same Wi-Fi uses the host's LAN IP. See the test plan for the full matrix.

import 'dart:io';

import 'package:socks5_proxy/socks_server.dart';

Future<void> main(List<String> args) async {
  final port = args.isNotEmpty ? int.tryParse(args.first) ?? 1080 : 1080;

  final server = SocksServer();
  try {
    await server.bind(InternetAddress.anyIPv4, port);
  } on SocketException catch (e) {
    stderr.writeln('Could not bind 0.0.0.0:$port — ${e.message}');
    stderr.writeln('Is another proxy already running on that port?');
    exitCode = 1;
    return;
  }

  stdout.writeln('SOCKS5 test proxy listening on 0.0.0.0:$port');
  stdout.writeln('Emulator: point the app at  10.0.2.2:$port');
  stdout.writeln('Real device: point it at    <this-host-LAN-IP>:$port');
  stdout.writeln('Each CONNECT below = one connection the app routed through '
      'the proxy. Ctrl+C to stop.\n');

  var n = 0;
  server.connections.listen((c) async {
    final id = ++n;
    final dest = '${c.desiredAddress.address}:${c.desiredPort}';
    final ts = DateTime.now().toIso8601String();
    stdout.writeln('[$ts] #$id CONNECT -> $dest');
    try {
      // forward() opens the target connection and pipes both directions.
      await c.forward(allowIPv6: true);
    } catch (e) {
      stdout.writeln('[$ts] #$id  forward FAILED for $dest: $e');
    }
  });
}
