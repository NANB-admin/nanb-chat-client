import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/features/chat/services/open_graph_parser.dart';

void main() {
  const parser = OpenGraphParser();
  final page = Uri.parse('https://example.com/post/1');

  String head(String inner) => '<html><head>$inner</head><body>hi</body></html>';

  group('OpenGraphParser.parse', () {
    test('reads og:title', () {
      final m = parser.parse(
          head('<meta property="og:title" content="Hello world">'), page);
      expect(m.title, 'Hello world');
    });

    test('reads og:description', () {
      final m = parser.parse(
          head('<meta property="og:description" content="A short summary">'),
          page);
      expect(m.description, 'A short summary');
    });

    test('reads og:image', () {
      final m = parser.parse(
          head('<meta property="og:image" content="https://cdn.example.com/a.jpg">'),
          page);
      expect(m.imageUrl, Uri.parse('https://cdn.example.com/a.jpg'));
    });

    test('resolves a relative og:image against the page address', () {
      final m = parser.parse(
          head('<meta property="og:image" content="/img/a.jpg">'), page);
      expect(m.imageUrl, Uri.parse('https://example.com/img/a.jpg'));
    });

    test('accepts attributes in either order', () {
      final m = parser.parse(
          head('<meta content="Reversed" property="og:title">'), page);
      expect(m.title, 'Reversed');
    });

    test('accepts single-quoted attribute values', () {
      final m = parser.parse(
          head("<meta property='og:title' content='Single'>"), page);
      expect(m.title, 'Single');
    });

    test('falls back to the twitter card tags', () {
      final m = parser.parse(
          head('<meta name="twitter:title" content="Tweeted">'), page);
      expect(m.title, 'Tweeted');
    });

    test('prefers Open Graph over twitter tags', () {
      final m = parser.parse(
          head('<meta name="twitter:title" content="T">'
              '<meta property="og:title" content="OG">'),
          page);
      expect(m.title, 'OG');
    });

    test('falls back to the <title> element', () {
      final m = parser.parse(head('<title>Plain title</title>'), page);
      expect(m.title, 'Plain title');
    });

    test('falls back to the meta description', () {
      final m = parser.parse(
          head('<meta name="description" content="Meta desc">'), page);
      expect(m.description, 'Meta desc');
    });

    test('decodes HTML entities', () {
      final m = parser.parse(
          head('<meta property="og:title" content="Tom &amp; Jerry &#39;s &quot;best&quot;">'),
          page);
      expect(m.title, 'Tom & Jerry \'s "best"');
    });

    test('collapses whitespace in the title', () {
      final m = parser.parse(head('<title>\n  Two\n   lines  </title>'), page);
      expect(m.title, 'Two lines');
    });

    test('ignores an image that is not http(s)', () {
      final m = parser.parse(
          head('<meta property="og:image" content="javascript:alert(1)">'),
          page);
      expect(m.imageUrl, isNull);
    });

    test('caps an overlong description', () {
      final long = 'x' * 1000;
      final m = parser.parse(
          head('<meta property="og:description" content="$long">'), page);
      expect(m.description.length, lessThanOrEqualTo(300));
    });

    test('is empty for a page with no metadata', () {
      expect(parser.parse('<html><body>nothing</body></html>', page).isEmpty,
          isTrue);
    });

    test('ignores tags that appear after the head', () {
      final m = parser.parse(
          '<html><head></head><body><meta property="og:title" content="Late"></body></html>',
          page);
      expect(m.title, '');
    });
  });
}
