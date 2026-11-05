import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../../core/crypto/media_cipher.dart';
import '../models/sticker.dart';
import '../models/sticker_image.dart';

/// The user's own stickers: image files in a private folder inside the app's
/// support directory. They are plaintext on disk (like any saved image), so the
/// folder is cleared on "Erase this device" / account switch via [clear].
///
/// A sticker's file name is the first 16 hex chars of the SHA-256 of its bytes,
/// so saving the same image twice is a no-op that just bumps it to the front.
class UserStickerStore {
  UserStickerStore({Future<Directory> Function()? directory})
      : _directory = directory ?? _defaultDirectory;

  final Future<Directory> Function() _directory;

  static Future<Directory> _defaultDirectory() async {
    final support = await getApplicationSupportDirectory();
    return Directory(p.join(support.path, 'stickers'));
  }

  /// Every saved sticker, most recently added (or re-added) first.
  Future<List<Sticker>> list() async {
    final dir = await _directory();
    if (!await dir.exists()) return const [];
    final files = <File>[];
    await for (final entity in dir.list()) {
      if (entity is File) files.add(entity);
    }
    final withTimes = [
      for (final f in files) (file: f, modified: await f.lastModified()),
    ]..sort((a, b) => b.modified.compareTo(a.modified));
    return [for (final e in withTimes) Sticker.file(e.file.path)];
  }

  Future<Sticker> add(StickerImage image) async {
    final dir = await _directory();
    await dir.create(recursive: true);
    final digest = await MediaCipher.sha256(image.bytes);
    final name = digest
        .take(8)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    final file = File(p.join(dir.path, '$name${_extension(image.mimeType)}'));
    if (await file.exists()) {
      await file.setLastModified(DateTime.now());
    } else {
      await file.writeAsBytes(image.bytes, flush: true);
    }
    return Sticker.file(file.path);
  }

  Future<void> remove(Sticker sticker) async {
    final path = sticker.filePath;
    if (path == null) return;
    final file = File(path);
    if (await file.exists()) await file.delete();
  }

  /// Deletes every saved sticker.
  Future<void> clear() async {
    final dir = await _directory();
    if (await dir.exists()) await dir.delete(recursive: true);
  }

  static String _extension(String mimeType) {
    switch (mimeType) {
      case 'image/webp':
        return '.webp';
      case 'image/gif':
        return '.gif';
      case 'image/jpeg':
        return '.jpg';
      default:
        return '.png';
    }
  }
}
