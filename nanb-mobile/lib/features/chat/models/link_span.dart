/// A URL found inside message text.
///
/// [start] (inclusive) and [end] (exclusive) are character offsets into the
/// text it was found in; [url] is the address to open (a bare `www.` link is
/// normalised to `https://`).
class LinkSpan {
  const LinkSpan({required this.start, required this.end, required this.url});

  final int start;
  final int end;
  final String url;

  @override
  bool operator ==(Object other) =>
      other is LinkSpan &&
      other.start == start &&
      other.end == end &&
      other.url == url;

  @override
  int get hashCode => Object.hash(start, end, url);

  @override
  String toString() => 'LinkSpan($start, $end, $url)';
}
