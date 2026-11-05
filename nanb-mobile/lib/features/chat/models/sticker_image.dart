/// An image that is ready to be stored or sent as a sticker: the (possibly
/// downscaled) encoded bytes plus the MIME type they are encoded as.
class StickerImage {
  const StickerImage({required this.bytes, required this.mimeType});

  final List<int> bytes;
  final String mimeType;
}
