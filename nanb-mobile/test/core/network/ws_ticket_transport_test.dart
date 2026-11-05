import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/core/network/ws_ticket_transport.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this._respond);

  final ResponseBody Function(RequestOptions) _respond;
  RequestOptions? lastRequest;
  int calls = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls++;
    lastRequest = options;
    return _respond(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _json(Object body, [int status = 200]) => ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );

class _FakeSink implements WebSocketSink {
  bool closed = false;

  @override
  Future<void> close([int? closeCode, String? closeReason]) async {
    closed = true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakeChannel implements WebSocketChannel {
  _FakeChannel({Object? handshakeError}) : _handshakeError = handshakeError;

  final Object? _handshakeError;
  final _FakeSink fakeSink = _FakeSink();

  @override
  Future<void> get ready =>
      _handshakeError == null ? Future.value() : Future.error(_handshakeError);

  @override
  WebSocketSink get sink => fakeSink;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _Harness {
  _Harness({
    ResponseBody Function(RequestOptions)? respond,
    Object? handshakeError,
  })  : adapter = _FakeAdapter(respond ?? (_) => _json({'ticket': 'tkt-123'})),
        channel = _FakeChannel(handshakeError: handshakeError) {
    final dio = Dio()..httpClientAdapter = adapter;
    transport = TicketWsTransport(
      dio: dio,
      openChannel: (url) {
        openedUrls.add(url);
        return channel;
      },
    );
  }

  final _FakeAdapter adapter;
  final _FakeChannel channel;
  final List<Uri> openedUrls = [];
  late final TicketWsTransport transport;
}

final _secureWsUrl = Uri.parse('wss://nanb.link/ws');

void main() {
  group('TicketWsTransport', () {
    test('exchanges the session for a ticket over POST /ws/ticket', () async {
      final h = _Harness();

      await h.transport.open(url: _secureWsUrl, jwt: 'jwt-abc');

      expect(h.adapter.lastRequest!.method, 'POST');
      expect(h.adapter.lastRequest!.uri.toString(), 'https://nanb.link/ws/ticket');
    });

    test('authenticates the ticket request with the bearer token', () async {
      final h = _Harness();

      await h.transport.open(url: _secureWsUrl, jwt: 'jwt-abc');

      expect(h.adapter.lastRequest!.headers['Authorization'], 'Bearer jwt-abc');
    });

    test('uses plain http for the ticket request when the socket is ws://', () async {
      final h = _Harness();

      await h.transport.open(url: Uri.parse('ws://127.0.0.1:8080/ws'), jwt: 'j');

      expect(h.adapter.lastRequest!.uri.toString(), 'http://127.0.0.1:8080/ws/ticket');
    });

    test('opens the socket with the ticket in the query string', () async {
      final h = _Harness();

      await h.transport.open(url: _secureWsUrl, jwt: 'jwt-abc');

      expect(h.openedUrls.single.toString(), 'wss://nanb.link/ws?ticket=tkt-123');
    });

    test('never puts the bearer token in the socket URL', () async {
      final h = _Harness();

      await h.transport.open(url: _secureWsUrl, jwt: 'jwt-abc');

      expect(h.openedUrls.single.toString(), isNot(contains('jwt-abc')));
    });

    test('returns the opened channel', () async {
      final h = _Harness();

      final conn = await h.transport.open(url: _secureWsUrl, jwt: 'j');

      expect(identical(conn.channel, h.channel), isTrue);
    });

    test('does not open a socket when the ticket request fails', () async {
      final h = _Harness(respond: (_) => _json({'code': 'unauthorized'}, 401));

      await expectLater(
        h.transport.open(url: _secureWsUrl, jwt: 'j'),
        throwsA(isA<DioException>()),
      );

      expect(h.openedUrls, isEmpty);
    });

    test('rejects a ticket response without a ticket', () async {
      final h = _Harness(respond: (_) => _json({'expires_in_seconds': 30}));

      await expectLater(
        h.transport.open(url: _secureWsUrl, jwt: 'j'),
        throwsA(isA<FormatException>()),
      );
    });

    test('rethrows a failed handshake so the supervisor backs off', () async {
      final h = _Harness(handshakeError: StateError('handshake refused'));

      await expectLater(
        h.transport.open(url: _secureWsUrl, jwt: 'j'),
        throwsA(isA<StateError>()),
      );
    });

    test('closes the channel after a failed handshake', () async {
      final h = _Harness(handshakeError: StateError('handshake refused'));

      await h.transport.open(url: _secureWsUrl, jwt: 'j').then((_) {}, onError: (_) {});
      await Future<void>.delayed(Duration.zero);

      expect(h.channel.fakeSink.closed, isTrue);
    });
  });
}
