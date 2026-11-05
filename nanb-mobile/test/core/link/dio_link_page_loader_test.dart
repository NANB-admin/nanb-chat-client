import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/core/link/dio_link_page_loader.dart';

typedef _Reply = ({
  int status,
  Map<String, String> headers,
  List<int> body,
});

/// Serves canned replies by URL and records what was requested.
class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.replies);

  final Map<String, _Reply> replies;
  final requested = <String>[];
  RequestOptions? lastOptions;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    lastOptions = options;
    requested.add(options.uri.toString());
    final reply = replies[options.uri.toString()];
    if (reply == null) return ResponseBody.fromBytes([], 404);
    return ResponseBody.fromBytes(
      reply.body,
      reply.status,
      headers: {
        for (final e in reply.headers.entries) e.key: [e.value],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

_Reply _ok(String contentType, List<int> body) =>
    (status: 200, headers: {'content-type': contentType}, body: body);

DioLinkPageLoader _loader(_FakeAdapter adapter) =>
    DioLinkPageLoader(dio: Dio()..httpClientAdapter = adapter);

void main() {
  group('DioLinkPageLoader.loadHtml', () {
    test('returns the page text', () async {
      final loader = _loader(_FakeAdapter({
        'https://a.com/': _ok('text/html; charset=utf-8', utf8.encode('<p>hi</p>')),
      }));

      expect(await loader.loadHtml(Uri.parse('https://a.com/')), '<p>hi</p>');
    });

    test('returns null for a non-HTML content type', () async {
      final loader = _loader(_FakeAdapter({
        'https://a.com/': _ok('application/pdf', [1, 2, 3]),
      }));

      expect(await loader.loadHtml(Uri.parse('https://a.com/')), isNull);
    });

    test('returns null for an error status', () async {
      final loader = _loader(_FakeAdapter({
        'https://a.com/': (
          status: 500,
          headers: {'content-type': 'text/html'},
          body: utf8.encode('oops'),
        ),
      }));

      expect(await loader.loadHtml(Uri.parse('https://a.com/')), isNull);
    });

    test('keeps only the first part of an oversized page', () async {
      final big = utf8.encode('<head>${'x' * (DioLinkPageLoader.maxHtmlBytes * 2)}');
      final loader = _loader(_FakeAdapter({
        'https://a.com/': _ok('text/html', big),
      }));

      final html = await loader.loadHtml(Uri.parse('https://a.com/'));

      expect(html!.length, lessThanOrEqualTo(DioLinkPageLoader.maxHtmlBytes));
    });

    test('follows a redirect to another public site', () async {
      final adapter = _FakeAdapter({
        'https://a.com/': (
          status: 302,
          headers: {'location': 'https://b.com/final'},
          body: <int>[],
        ),
        'https://b.com/final': _ok('text/html', utf8.encode('<p>b</p>')),
      });

      expect(await _loader(adapter).loadHtml(Uri.parse('https://a.com/')),
          '<p>b</p>');
    });

    test('refuses a redirect into a private address', () async {
      final adapter = _FakeAdapter({
        'https://a.com/': (
          status: 302,
          headers: {'location': 'http://192.168.1.1/admin'},
          body: <int>[],
        ),
        'http://192.168.1.1/admin': _ok('text/html', utf8.encode('secret')),
      });

      expect(await _loader(adapter).loadHtml(Uri.parse('https://a.com/')),
          isNull);
      expect(adapter.requested, ['https://a.com/']);
    });

    test('gives up on a redirect loop', () async {
      final adapter = _FakeAdapter({
        'https://a.com/': (
          status: 302,
          headers: {'location': 'https://a.com/'},
          body: <int>[],
        ),
      });

      expect(await _loader(adapter).loadHtml(Uri.parse('https://a.com/')),
          isNull);
    });

    test('sends no cookies or credentials', () async {
      final adapter = _FakeAdapter({
        'https://a.com/': _ok('text/html', utf8.encode('x')),
      });
      await _loader(adapter).loadHtml(Uri.parse('https://a.com/'));

      final names = adapter.lastOptions!.headers.keys.map((k) => k.toLowerCase());
      expect(names, isNot(contains('cookie')));
      expect(names, isNot(contains('authorization')));
    });
  });

  group('DioLinkPageLoader.loadImage', () {
    test('returns the image bytes', () async {
      final loader = _loader(_FakeAdapter({
        'https://a.com/p.png': _ok('image/png', [1, 2, 3]),
      }));

      expect(await loader.loadImage(Uri.parse('https://a.com/p.png')),
          [1, 2, 3]);
    });

    test('returns null for a non-image content type', () async {
      final loader = _loader(_FakeAdapter({
        'https://a.com/p': _ok('text/html', [1]),
      }));

      expect(await loader.loadImage(Uri.parse('https://a.com/p')), isNull);
    });

    test('returns null for an SVG image', () async {
      final loader = _loader(_FakeAdapter({
        'https://a.com/p.svg': _ok('image/svg+xml', [1]),
      }));

      expect(await loader.loadImage(Uri.parse('https://a.com/p.svg')), isNull);
    });

    test('returns null for an oversized image', () async {
      final loader = _loader(_FakeAdapter({
        'https://a.com/big.jpg': _ok(
            'image/jpeg', List.filled(DioLinkPageLoader.maxImageBytes + 1, 0)),
      }));

      expect(await loader.loadImage(Uri.parse('https://a.com/big.jpg')),
          isNull);
    });
  });
}
