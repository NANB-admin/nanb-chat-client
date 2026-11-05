/// Downloads the two things a link preview needs. Each returns null on any
/// failure (timeout, error status, too large, wrong content type) — a preview is
/// best-effort and a failure just means no card.
abstract class LinkPageLoader {
  /// The page's HTML, capped to a small size.
  Future<String?> loadHtml(Uri url);

  /// The raw bytes of a preview image, capped to a small size.
  Future<List<int>?> loadImage(Uri url);
}
