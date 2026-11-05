import '../models/page_metadata.dart';

/// Pulls a page's title / description / image out of its HTML `<head>`.
///
/// Deliberately regex-based and head-only: link previews read a few `<meta>`
/// tags, not the page, and untrusted HTML never reaches a real parser or a
/// WebView. Open Graph tags win over Twitter-card tags, which win over the plain
/// `<title>` / `description` fallbacks.
class OpenGraphParser {
  const OpenGraphParser();

  static const maxTitleLength = 150;
  static const maxDescriptionLength = 300;

  /// Cap for a head with no `</head>` (some pages never close it).
  static const _headlessScanLimit = 64 * 1024;

  static final _metaTag = RegExp(r'<meta\b[^>]*>', caseSensitive: false);
  static final _attribute = RegExp(
    r'''([a-zA-Z:_-]+)\s*=\s*(?:"([^"]*)"|'([^']*)')''',
  );
  static final _titleTag = RegExp(
    r'<title\b[^>]*>(.*?)</title>',
    caseSensitive: false,
    dotAll: true,
  );
  static final _headEnd = RegExp(r'</head\s*>', caseSensitive: false);

  /// [pageUrl] is the address the HTML came from, used to resolve a relative
  /// image address.
  PageMetadata parse(String html, Uri pageUrl) {
    final headEnd = _headEnd.firstMatch(html)?.start;
    final head = html.substring(
      0,
      headEnd ?? (html.length < _headlessScanLimit ? html.length : _headlessScanLimit),
    );

    final tags = <String, String>{};
    for (final m in _metaTag.allMatches(head)) {
      final attrs = <String, String>{};
      for (final a in _attribute.allMatches(m.group(0)!)) {
        attrs[a.group(1)!.toLowerCase()] = a.group(2) ?? a.group(3) ?? '';
      }
      final key = (attrs['property'] ?? attrs['name'])?.toLowerCase();
      final content = attrs['content'];
      if (key == null || content == null) continue;
      tags.putIfAbsent(key, () => content);
    }

    String firstOf(List<String> keys) {
      for (final k in keys) {
        final v = _clean(tags[k] ?? '');
        if (v.isNotEmpty) return v;
      }
      return '';
    }

    var title = firstOf(['og:title', 'twitter:title']);
    if (title.isEmpty) {
      title = _clean(_titleTag.firstMatch(head)?.group(1) ?? '');
    }
    final description =
        firstOf(['og:description', 'twitter:description', 'description']);
    final image = firstOf(['og:image', 'og:image:url', 'twitter:image']);

    return PageMetadata(
      title: _cap(title, maxTitleLength),
      description: _cap(description, maxDescriptionLength),
      imageUrl: _resolveImage(image, pageUrl),
    );
  }

  Uri? _resolveImage(String raw, Uri pageUrl) {
    if (raw.isEmpty) return null;
    final parsed = Uri.tryParse(raw);
    if (parsed == null) return null;
    final resolved = pageUrl.resolveUri(parsed);
    if (resolved.scheme != 'http' && resolved.scheme != 'https') return null;
    if (resolved.host.isEmpty) return null;
    return resolved;
  }

  String _cap(String s, int max) => s.length <= max ? s : s.substring(0, max);

  /// Decodes HTML entities and collapses runs of whitespace.
  String _clean(String raw) {
    return _decodeEntities(raw).replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  static const _named = {
    'amp': '&',
    'lt': '<',
    'gt': '>',
    'quot': '"',
    'apos': "'",
    'nbsp': ' ',
  };

  String _decodeEntities(String s) {
    return s.replaceAllMapped(RegExp(r'&(#x[0-9a-fA-F]+|#\d+|[a-zA-Z]+);'), (m) {
      final body = m.group(1)!;
      if (body.startsWith('#x') || body.startsWith('#X')) {
        final code = int.tryParse(body.substring(2), radix: 16);
        return code == null ? m.group(0)! : String.fromCharCode(code);
      }
      if (body.startsWith('#')) {
        final code = int.tryParse(body.substring(1));
        return code == null ? m.group(0)! : String.fromCharCode(code);
      }
      return _named[body.toLowerCase()] ?? m.group(0)!;
    });
  }
}
