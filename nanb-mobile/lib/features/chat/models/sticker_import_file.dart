import 'dart:typed_data';

/// One file handed to the sticker importer: a loose image, or a `.wastickers`
/// / `.zip` bundle of them. Carries bytes (not a path) so the importer stays
/// free of platform file access.
class StickerImportFile {
  const StickerImportFile({required this.name, required this.bytes});

  final String name;
  final Uint8List bytes;
}
