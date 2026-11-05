/// A single GIF result from the nanb-server GIF proxy (`/gifs/*`). The server
/// normalizes the upstream provider's response down to just the two renditions
/// the picker uses — a lightweight animated preview for the grid, and a small
/// rendition we actually download + send (kept modest so the encrypted upload
/// stays small) — so the client never sees the provider's response schema.
class GifResult {
  const GifResult({
    required this.id,
    required this.previewUrl,
    required this.sendUrl,
    required this.width,
    required this.height,
  });

  final String id;

  /// Animated, downsampled rendition shown in the picker grid (small download).
  final String previewUrl;

  /// Rendition we download and send through the media pipeline. A downsized
  /// variant so the AES-GCM blob stays small.
  final String sendUrl;

  final double width;
  final double height;

  double get aspectRatio => (width <= 0 || height <= 0) ? 1 : width / height;

  /// Parses one entry from the proxy's `data[]` array. Returns null when the
  /// required fields are missing/malformed, so callers can filter them out.
  static GifResult? fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final preview = json['previewUrl'];
    final send = json['sendUrl'];
    if (id is! String || preview is! String || send is! String) return null;

    double dim(String key) {
      final v = json[key];
      if (v is num) return v.toDouble();
      if (v is String) return double.tryParse(v) ?? 0;
      return 0;
    }

    return GifResult(
      id: id,
      previewUrl: preview,
      sendUrl: send,
      width: dim('width'),
      height: dim('height'),
    );
  }
}
