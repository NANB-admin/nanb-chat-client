/// Outcome of a sticker import: how many images became stickers and how many
/// files/entries were skipped (not images, unreadable, or tray icons).
class StickerImportResult {
  const StickerImportResult({required this.added, required this.skipped});

  final int added;
  final int skipped;
}
