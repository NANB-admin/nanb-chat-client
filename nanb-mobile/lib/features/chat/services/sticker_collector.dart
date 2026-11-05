import '../models/sticker.dart';
import 'sticker_normalizer.dart';
import 'user_sticker_store.dart';

/// Saves an image as one of the user's stickers: normalizes it (size/format) and
/// hands it to the [UserStickerStore]. Shared by the "Add to stickers" message
/// action and the picker's "+" button so both behave identically.
class StickerCollector {
  StickerCollector({
    required StickerNormalizer normalizer,
    required UserStickerStore store,
  })  : _normalizer = normalizer,
        _store = store;

  final StickerNormalizer _normalizer;
  final UserStickerStore _store;

  /// Returns the saved sticker, or null when [bytes] isn't a decodable image.
  Future<Sticker?> addFromBytes(List<int> bytes, String mimeType) async {
    final image = await _normalizer.normalize(bytes, mimeType);
    if (image == null) return null;
    return _store.add(image);
  }
}
