import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/features/chat/models/link_span.dart';
import 'package:nanb_chat/features/chat/services/link_detector.dart';

void main() {
  group('LinkDetector.find', () {
    test('finds an https link inside a sentence', () {
      const text = 'look at https://example.com/page now';
      expect(LinkDetector.find(text), [
        const LinkSpan(start: 8, end: 32, url: 'https://example.com/page'),
      ]);
    });

    test('finds an http link', () {
      expect(LinkDetector.find('http://example.com').single.url,
          'http://example.com');
    });

    test('opens a bare www link over https', () {
      final link = LinkDetector.find('see www.example.com/x').single;
      expect(link.url, 'https://www.example.com/x');
    });

    test('the span covers exactly what the user typed for a www link', () {
      const text = 'see www.example.com/x';
      final link = LinkDetector.find(text).single;
      expect(text.substring(link.start, link.end), 'www.example.com/x');
    });

    test('keeps the query string and fragment of an Instagram share link', () {
      const url = 'https://www.instagram.com/reel/Cabc123xyz/?igsh=MWx0bTdq#top';
      expect(LinkDetector.find('check this $url').single.url, url);
    });

    test('does not swallow a sentence-ending period', () {
      final link = LinkDetector.find('Go to https://example.com.').single;
      expect(link.url, 'https://example.com');
    });

    test('does not swallow a trailing comma', () {
      final link = LinkDetector.find('https://example.com, then more').single;
      expect(link.url, 'https://example.com');
    });

    test('does not swallow trailing question or exclamation marks', () {
      final link = LinkDetector.find('is it https://example.com/a?!').single;
      expect(link.url, 'https://example.com/a');
    });

    test('does not swallow a closing parenthesis that wraps the link', () {
      final link = LinkDetector.find('(see https://example.com/a)').single;
      expect(link.url, 'https://example.com/a');
    });

    test('keeps balanced parentheses that are part of the address', () {
      const url = 'https://en.wikipedia.org/wiki/Dart_(programming_language)';
      expect(LinkDetector.find('read $url').single.url, url);
    });

    test('finds several links in one message, in order', () {
      final links =
          LinkDetector.find('a https://one.example b www.two.example c');
      expect(links.map((l) => l.url),
          ['https://one.example', 'https://www.two.example']);
    });

    test('finds a link on its own line of a multi-line message', () {
      final link = LinkDetector.find('hey\nhttps://example.com\nbye').single;
      expect(link.url, 'https://example.com');
    });

    test('finds nothing in plain text', () {
      expect(LinkDetector.find('just a normal message, e.g. nothing here'),
          isEmpty);
    });

    test('ignores schemes other than http and https', () {
      expect(LinkDetector.find('javascript:alert(1) ftp://example.com'),
          isEmpty);
    });

    test('ignores a scheme with no address after it', () {
      expect(LinkDetector.find('https:// and www.'), isEmpty);
    });

    test('matches the scheme case-insensitively', () {
      expect(LinkDetector.find('HTTPS://Example.com').single.url,
          'HTTPS://Example.com');
    });
  });
}
