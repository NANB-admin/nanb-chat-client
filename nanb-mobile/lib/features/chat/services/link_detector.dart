import '../models/link_span.dart';

/// Finds web links in message text so the bubble can make them tappable.
///
/// Only `http://`, `https://` and bare `www.` addresses count — never other
/// schemes (`javascript:`, `intent:` …), so a message can't smuggle a tap
/// target that does something other than open a web page.
class LinkDetector {
  const LinkDetector._();

  static final RegExp _candidate = RegExp(
    r'(?:https?://|www\.)[^\s<>]+',
    caseSensitive: false,
  );

  /// Punctuation that ends a sentence, not an address: never part of the link
  /// when it comes last.
  static const String _trailingPunctuation = '.,;:!?\'"…';

  static const Map<String, String> _openers = {')': '(', ']': '[', '}': '{'};

  /// The links in [text], in order.
  static List<LinkSpan> find(String text) {
    final links = <LinkSpan>[];
    for (final match in _candidate.allMatches(text)) {
      final end = _trimmedEnd(text, match.start, match.end);
      final raw = text.substring(match.start, end);
      final url = _openableUrl(raw);
      if (url == null) continue;
      links.add(LinkSpan(start: match.start, end: end, url: url));
    }
    return links;
  }

  /// Peels sentence punctuation, and a closing bracket that has no opener in
  /// the link, off the end of `text[start, end)`.
  static int _trimmedEnd(String text, int start, int end) {
    var e = end;
    while (e > start) {
      final ch = text[e - 1];
      if (_trailingPunctuation.contains(ch)) {
        e--;
      } else if (_openers.containsKey(ch) &&
          _isUnbalanced(text.substring(start, e), ch)) {
        e--;
      } else {
        break;
      }
    }
    return e;
  }

  static bool _isUnbalanced(String link, String closer) {
    final opener = _openers[closer]!;
    return closer.allMatches(link).length > opener.allMatches(link).length;
  }

  /// The address to launch for [raw], or null if it isn't a real link (a
  /// scheme with nothing after it, a `www.` with no domain).
  static String? _openableUrl(String raw) {
    final bareWww = raw.toLowerCase().startsWith('www.');
    if (bareWww && !raw.substring(4).contains('.')) return null;
    final url = bareWww ? 'https://$raw' : raw;
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty) return null;
    return url;
  }
}
