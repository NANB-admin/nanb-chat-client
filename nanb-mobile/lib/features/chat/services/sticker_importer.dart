import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../models/sticker_import_file.dart';
import '../models/sticker_import_result.dart';
import 'sticker_collector.dart';

/// Imports stickers from outside the app: loose image files and the sticker
/// bundles other apps export (`.wastickers`, which is a zip of WebP images plus
/// metadata, and plain `.zip` packs).
///
/// Every image goes through [StickerCollector], so imported stickers are
/// normalized and de-duplicated exactly like ones the user makes in-app.
class StickerImporter {
  StickerImporter(this._collector);

  final StickerCollector _collector;

  /// Hard cap on stickers taken from one import, so a malicious or huge
  /// archive can't fill storage.
  static const int maxStickers = 120;

  static const _imageMimes = <String, String>{
    'webp': 'image/webp',
    'png': 'image/png',
    'gif': 'image/gif',
    'jpg': 'image/jpeg',
    'jpeg': 'image/jpeg',
  };

  static const _bundleExtensions = {'wastickers', 'zip'};

  Future<StickerImportResult> import(List<StickerImportFile> files) async {
    var added = 0;
    var skipped = 0;
    for (final file in files) {
      final ext = _extension(file.name);
      final entries = <StickerImportFile>[];
      if (_bundleExtensions.contains(ext)) {
        final unpacked = _unpack(file.bytes);
        if (unpacked == null || unpacked.isEmpty) {
          skipped++;
          continue;
        }
        entries.addAll(unpacked);
      } else {
        entries.add(file);
      }
      for (final entry in entries) {
        if (added >= maxStickers) return StickerImportResult(added: added, skipped: skipped + 1);
        final mime = _imageMimes[_extension(entry.name)];
        if (mime == null || _isTrayIcon(entry.name)) {
          skipped++;
          continue;
        }
        final saved = await _collector.addFromBytes(entry.bytes, mime);
        if (saved == null) {
          skipped++;
        } else {
          added++;
        }
      }
    }
    return StickerImportResult(added: added, skipped: skipped);
  }

  /// Image entries of a zip-style bundle, or null when it isn't a readable
  /// archive. Metadata files (`author.txt`, `title.txt`, …) are ignored later
  /// by the image-extension filter.
  List<StickerImportFile>? _unpack(Uint8List bytes) {
    try {
      final archive = ZipDecoder().decodeBytes(bytes);
      return [
        for (final e in archive)
          if (e.isFile)
            StickerImportFile(
              name: e.name,
              bytes: Uint8List.fromList(e.content as List<int>),
            ),
      ];
    } catch (_) {
      return null;
    }
  }

  /// WhatsApp-style packs ship a `tray.png` pack icon that isn't a sticker.
  static bool _isTrayIcon(String name) =>
      name.split('/').last.toLowerCase().startsWith('tray');

  static String _extension(String name) {
    final dot = name.lastIndexOf('.');
    return dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
  }
}
