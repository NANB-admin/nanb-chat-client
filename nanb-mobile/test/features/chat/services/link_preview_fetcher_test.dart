import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/features/chat/services/link_page_loader.dart';
import 'package:nanb_chat/features/chat/services/link_preview_fetcher.dart';

class _FakeLoader implements LinkPageLoader {
  _FakeLoader({this.html, this.image});

  String? html;
  List<int>? image;
  final htmlRequests = <Uri>[];
  final imageRequests = <Uri>[];

  @override
  Future<String?> loadHtml(Uri url) async {
    htmlRequests.add(url);
    return html;
  }

  @override
  Future<List<int>?> loadImage(Uri url) async {
    imageRequests.add(url);
    return image;
  }
}

const _page = '''
<html><head>
<meta property="og:title" content="A reel">
<meta property="og:description" content="Look at this">
<meta property="og:image" content="https://cdn.example.com/p.jpg">
</head></html>''';

LinkPreviewFetcher _fetcher(
  _FakeLoader loader, {
  Future<List<int>?> Function(List<int>)? thumbnail,
}) =>
    LinkPreviewFetcher(
      loader: loader,
      makeThumbnail: thumbnail ?? (bytes) async => [1, 2, 3],
    );

void main() {
  group('LinkPreviewFetcher.fetch', () {
    test('builds a preview from the page metadata', () async {
      final p = await _fetcher(_FakeLoader(html: _page, image: [9]))
          .fetch('https://example.com/post');

      expect(p!.title, 'A reel');
      expect(p.description, 'Look at this');
    });

    test('keeps the link it was asked about as the preview url', () async {
      final p = await _fetcher(_FakeLoader(html: _page, image: [9]))
          .fetch('https://example.com/post');

      expect(p!.url, 'https://example.com/post');
    });

    test('attaches the downscaled thumbnail', () async {
      final p = await _fetcher(_FakeLoader(html: _page, image: [9]))
          .fetch('https://example.com/post');

      expect(p!.thumbnail, [1, 2, 3]);
    });

    test('still returns a card when the image cannot be downloaded', () async {
      final p = await _fetcher(_FakeLoader(html: _page, image: null))
          .fetch('https://example.com/post');

      expect(p!.title, 'A reel');
      expect(p.thumbnail, isNull);
    });

    test('still returns a card when the image cannot be decoded', () async {
      final p = await _fetcher(_FakeLoader(html: _page, image: [9]),
              thumbnail: (_) async => null)
          .fetch('https://example.com/post');

      expect(p!.thumbnail, isNull);
    });

    test('returns null when the page cannot be downloaded', () async {
      expect(
          await _fetcher(_FakeLoader(html: null))
              .fetch('https://example.com/post'),
          isNull);
    });

    test('returns null when the page has no metadata', () async {
      expect(
          await _fetcher(_FakeLoader(html: '<html><body>x</body></html>'))
              .fetch('https://example.com/post'),
          isNull);
    });

    test('falls back to the host as title when only a description exists',
        () async {
      final p = await _fetcher(_FakeLoader(
              html: '<head><meta name="description" content="Just text"></head>'))
          .fetch('https://example.com/post');

      expect(p!.title, 'example.com');
    });

    test('never contacts a private address', () async {
      final loader = _FakeLoader(html: _page);
      final p = await _fetcher(loader).fetch('http://192.168.1.1/admin');

      expect(p, isNull);
      expect(loader.htmlRequests, isEmpty);
    });

    test('does not download an image that points at a private address',
        () async {
      final loader = _FakeLoader(
        html: '<head><meta property="og:title" content="T">'
            '<meta property="og:image" content="http://10.0.0.1/x.png"></head>',
        image: [9],
      );
      final p = await _fetcher(loader).fetch('https://example.com/post');

      expect(loader.imageRequests, isEmpty);
      expect(p!.thumbnail, isNull);
    });

    test('returns null for an unparseable address', () async {
      expect(await _fetcher(_FakeLoader(html: _page)).fetch('not a url'),
          isNull);
    });
  });
}
