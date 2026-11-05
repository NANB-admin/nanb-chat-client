import '../models/link_preview.dart';
import 'fetchable_url_policy.dart';
import 'link_page_loader.dart';
import 'open_graph_parser.dart';

/// Turns a link into a [LinkPreview] card: fetches the page's `<head>`, reads its
/// title / description / image, and shrinks the image to a thumbnail small enough
/// to ride inside an encrypted message.
///
/// The [loader] decides HOW the network is reached — the app wires it through the
/// Tor SOCKS proxy — so this class stays pure and testable. Best effort: any
/// failure yields null (no card), never an error to the sender.
class LinkPreviewFetcher {
  LinkPreviewFetcher({
    required LinkPageLoader loader,
    required Future<List<int>?> Function(List<int> imageBytes) makeThumbnail,
    OpenGraphParser parser = const OpenGraphParser(),
    FetchableUrlPolicy policy = const FetchableUrlPolicy(),
  })  : _loader = loader,
        _makeThumbnail = makeThumbnail,
        _parser = parser,
        _policy = policy;

  final LinkPageLoader _loader;
  final Future<List<int>?> Function(List<int>) _makeThumbnail;
  final OpenGraphParser _parser;
  final FetchableUrlPolicy _policy;

  Future<LinkPreview?> fetch(String link) async {
    final url = Uri.tryParse(link);
    if (url == null || !_policy.allows(url)) return null;

    final html = await _loader.loadHtml(url);
    if (html == null) return null;
    final meta = _parser.parse(html, url);
    if (meta.isEmpty) return null;

    List<int>? thumbnail;
    final imageUrl = meta.imageUrl;
    if (imageUrl != null && _policy.allows(imageUrl)) {
      final bytes = await _loader.loadImage(imageUrl);
      if (bytes != null) thumbnail = await _makeThumbnail(bytes);
    }

    return LinkPreview(
      url: link,
      // A page with a description but no title still gets a card, headed by
      // its site name.
      title: meta.title.isNotEmpty ? meta.title : url.host,
      description: meta.description,
      thumbnail: thumbnail,
    );
  }
}
