import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/core/models/api_error.dart';
import 'package:nanb_chat/core/models/envelope.dart';
import 'package:nanb_chat/core/network/api_client.dart';
import 'package:nanb_chat/core/network/api_client_dio.dart';

/// Lightweight Dio adapter for tests — answers each request with a
/// pre-canned [ResponseBody] (200 success or non-2xx error). Replaces
/// the production HttpClientAdapter so no real network call happens.
class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this._handler);

  final ResponseBody Function(RequestOptions options) _handler;
  String? lastPath;
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    lastPath = options.path;
    requests.add(options);
    return _handler(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _bytesResponse(int statusCode, List<int> bytes) {
  return ResponseBody.fromBytes(
    Uint8List.fromList(bytes),
    statusCode,
    headers: {
      Headers.contentTypeHeader: ['application/octet-stream'],
    },
  );
}

ResponseBody _jsonResponse(int statusCode, Map<String, dynamic> body) {
  final bytes = Uint8List.fromList(utf8.encode(jsonEncode(body)));
  return ResponseBody.fromBytes(
    bytes,
    statusCode,
    headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    },
  );
}

ApiClientDio _buildClient(_FakeAdapter adapter, {bool onTor = false}) {
  final dio = Dio(BaseOptions(baseUrl: 'http://test.example'));
  dio.httpClientAdapter = adapter;
  final client =
      ApiClientDio(baseUrl: 'http://test.example', dio: dio, onTor: onTor);
  // Authed endpoints now REFUSE to go out without a bearer (see the
  // `no_session` guard in ApiClientDio._authHeaders), so give every client the
  // token a real post-login client would carry. Tests that care about the
  // header's value re-set it themselves; the no-bearer refusal has its own test.
  client.setBearerToken('jwt-token');
  return client;
}

Map<String, dynamic> _envelopeJson(String envelopeId) => {
      'envelope_id': envelopeId,
      'version': 'v1',
      'domain': 'nanb.link',
      'envelope_type': 'mls_application',
      'conversation_id': 'group:g1',
      'sender_device_id': 'peer',
      'recipient_account_id': 'me-acc',
      'recipient_device_id': 'me-dev',
      'ciphertext': [1, 2, 3, 4],
      'server_ts': '2026-05-17T12:00:00Z',
    };

void main() {
  group('ApiClientDio auth guard', () {
    test('an authed request without a bearer never reaches the network',
        () async {
      final adapter = _FakeAdapter((opts) => _jsonResponse(200, {}));
      final dio = Dio(BaseOptions(baseUrl: 'http://test.example'));
      dio.httpClientAdapter = adapter;
      final api = ApiClientDio(baseUrl: 'http://test.example', dio: dio);

      await expectLater(
        () => api.getEnvelopeById('env-1'),
        throwsA(isA<ApiError>()),
      );
      expect(adapter.lastPath, isNull);
    });

    test('the no-bearer refusal is TRANSIENT (no status), so callers retry it',
        () async {
      // The Tor-bootstrap window rebuilds this client with no bearer for a beat.
      // Sending anonymously would earn a 401 — a status code, which every
      // transience check reads as permanent, destroying the outbox message.
      final adapter = _FakeAdapter((opts) => _jsonResponse(200, {}));
      final dio = Dio(BaseOptions(baseUrl: 'http://test.example'));
      dio.httpClientAdapter = adapter;
      final api = ApiClientDio(baseUrl: 'http://test.example', dio: dio);

      try {
        await api.getEnvelopeById('env-1');
        fail('expected the auth guard to throw');
      } on ApiError catch (e) {
        expect(e.statusCode, isNull);
        expect(e.code, 'no_session');
      }
    });
  });

  group('ApiClientDio.getEnvelopeById', () {
    test('issues GET to /messages/by-id/{envelopeId} and returns the parsed envelope', () async {
      final adapter = _FakeAdapter(
        (opts) => _jsonResponse(200, _envelopeJson('env-1')),
      );
      final api = _buildClient(adapter);
      final env = await api.getEnvelopeById('env-1');
      expect(adapter.lastPath, '/messages/by-id/env-1');
      expect(env, isA<Envelope>());
      expect(env.envelopeId, 'env-1');
      expect(env.ciphertext, [1, 2, 3, 4]);
    });

    test('throws ApiError when server responds 404', () async {
      final adapter = _FakeAdapter(
        (opts) => _jsonResponse(404, {
          'code': 'envelope_not_found',
          'message': 'no envelope addressed to caller',
        }),
      );
      final api = _buildClient(adapter);
      expect(
        () => api.getEnvelopeById('missing-env'),
        throwsA(isA<ApiError>()),
      );
    });
  });

  // Media-fetch transport routing: off Tor we use the presigned/CloudFront URL
  // (CDN performance); on Tor we stream from the server's onion endpoint so the
  // bytes never egress via a Tor exit node. `getMedia` returns the pointer and
  // `getBytesFromUrl` fetches it — callers don't branch on transport.
  group('media fetch routing (Tor vs CDN)', () {
    test('OFF Tor: getMedia POSTs /media/get and returns the presigned URL', () async {
      final adapter = _FakeAdapter(
        (opts) => _jsonResponse(200, {
          'download_url': 'https://cdn.example/media/m-1?sig=abc',
          'download_expiry': '2026-06-16T12:00:00Z',
          'mime_type': 'image/png',
          'size_bytes': 123,
        }),
      );
      final api = _buildClient(adapter, onTor: false);

      final pointer = await api.getMedia('m-1');

      expect(adapter.lastPath, '/media/get');
      expect(pointer.downloadUrl, 'https://cdn.example/media/m-1?sig=abc');
      expect(pointer.sizeBytes, 123);
    });

    test('OFF Tor: getBytesFromUrl hits the absolute presigned URL WITHOUT a bearer header', () async {
      final adapter = _FakeAdapter((opts) => _bytesResponse(200, [9, 8, 7]));
      final api = _buildClient(adapter, onTor: false);
      api.setBearerToken('jwt-token');

      final bytes = await api.getBytesFromUrl('https://cdn.example/media/m-1?sig=abc');

      expect(bytes, [9, 8, 7]);
      final req = adapter.requests.single;
      expect(req.path, 'https://cdn.example/media/m-1?sig=abc');
      // Presigned URLs carry their own auth — no bearer token leaks to the CDN.
      expect(req.headers.containsKey('Authorization'), isFalse);
    });

    test('ON Tor: getMedia returns the /media/stream pointer WITHOUT calling /media/get', () async {
      final adapter = _FakeAdapter((opts) => _jsonResponse(200, const {}));
      final api = _buildClient(adapter, onTor: true);

      final pointer = await api.getMedia('m-1');

      // No network round trip to resolve a presigned URL on Tor.
      expect(adapter.requests, isEmpty);
      expect(pointer.downloadUrl, '/media/stream?media_id=m-1');
    });

    test('ON Tor: getBytesFromUrl streams /media/stream WITH the bearer header', () async {
      final adapter = _FakeAdapter((opts) => _bytesResponse(200, [1, 2, 3, 4]));
      final api = _buildClient(adapter, onTor: true);
      api.setBearerToken('jwt-token');

      final bytes = await api.getBytesFromUrl('/media/stream?media_id=m-1');

      expect(bytes, [1, 2, 3, 4]);
      final req = adapter.requests.single;
      expect(req.method, 'GET');
      expect(req.path, '/media/stream?media_id=m-1');
      // The onion stream endpoint is authed (it's our own server).
      expect(req.headers['Authorization'], 'Bearer jwt-token');
    });

    test('ON Tor: end-to-end getMedia → getBytesFromUrl yields the streamed bytes', () async {
      final adapter = _FakeAdapter((opts) {
        expect(opts.path, '/media/stream?media_id=m-9');
        return _bytesResponse(200, [42, 43]);
      });
      final api = _buildClient(adapter, onTor: true);
      api.setBearerToken('jwt-token');

      final pointer = await api.getMedia('m-9');
      final bytes = await api.getBytesFromUrl(pointer.downloadUrl);

      expect(bytes, [42, 43]);
    });
  });

  group('unauthenticated sealed deposit', () {
    SubmitMessagePayload sealedPayload() => SubmitMessagePayload(
          conversationId: '',
          envelopeType: 'sealed',
          recipientAccountId: 'peer-acc',
          recipientDeviceId: 'peer-dev',
          ciphertext: [1, 2, 3],
        );

    _FakeAdapter acceptingAdapter() => _FakeAdapter((_) => _jsonResponse(200, {
          'envelope_id': 'env-1',
          'server_ts': '2026-10-21T12:00:00Z',
        }));

    test('off Tor it gives up connecting quickly so the authed fallback runs',
        () async {
      final adapter = acceptingAdapter();
      final api = _buildClient(adapter);

      await api.submitSealedUnauthenticated(sealedPayload(), [9, 9]);

      expect(adapter.requests.single.connectTimeout,
          ApiClientDio.unauthConnectTimeout);
    });

    test('on Tor it keeps the client default connect budget', () async {
      final adapter = acceptingAdapter();
      final api = _buildClient(adapter, onTor: true);

      await api.submitSealedUnauthenticated(sealedPayload(), [9, 9]);

      expect(adapter.requests.single.connectTimeout,
          isNot(ApiClientDio.unauthConnectTimeout));
    });
  });
}
