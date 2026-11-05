/// One sendable sticker: either bundled with the app (a Flutter asset) or made
/// by the user (a file in the app's private storage). Equality is by [id], so
/// two handles to the same sticker compare equal and work as widget keys.
class Sticker {
  const Sticker.asset(String path)
      : assetPath = path,
        filePath = null;

  const Sticker.file(String path)
      : filePath = path,
        assetPath = null;

  /// Set for a bundled sticker, null otherwise.
  final String? assetPath;

  /// Set for a user-made sticker, null otherwise.
  final String? filePath;

  bool get isUserMade => filePath != null;

  /// Stable identity: the asset path or the file path.
  String get id => assetPath ?? filePath!;

  /// MIME type inferred from the file extension, which is how the sender tells
  /// the recipient how to decode the bytes. Unknown extensions fall back to PNG
  /// (the format every bundled sticker uses).
  String get mimeType {
    final lower = id.toLowerCase();
    if (lower.endsWith('.webp')) return 'image/webp';
    if (lower.endsWith('.gif')) return 'image/gif';
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
    return 'image/png';
  }

  @override
  bool operator ==(Object other) => other is Sticker && other.id == id;

  @override
  int get hashCode => id.hashCode;
}
