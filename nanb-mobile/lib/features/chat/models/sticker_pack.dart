import 'sticker.dart';

/// A named group of bundled stickers, shown as one tab in the sticker picker.
class StickerPack {
  const StickerPack({
    required this.id,
    required this.title,
    required this.stickers,
  });

  /// The pack's directory name under `assets/stickers/`.
  final String id;
  final String title;
  final List<Sticker> stickers;

  /// The sticker shown as the pack's tab icon.
  Sticker get cover => stickers.first;
}
