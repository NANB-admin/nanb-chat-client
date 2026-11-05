import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Keeps the user's chosen chat-background photo in the app's private storage,
/// so it survives the gallery copy being moved or deleted.
class ChatBackgroundStore {
  const ChatBackgroundStore();

  static const _prefix = 'chat_background_';

  /// Copies [sourcePath] into app storage under a fresh name (a new name per
  /// pick defeats Flutter's image cache) and removes any earlier copy. Returns
  /// the new path.
  Future<String> save(String sourcePath) async {
    final dir = await getApplicationSupportDirectory();
    final ext = p.extension(sourcePath).isEmpty ? '.jpg' : p.extension(sourcePath);
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final dest = p.join(dir.path, '$_prefix$stamp$ext');
    await File(sourcePath).copy(dest);
    await _deleteOthers(dir, keep: dest);
    return dest;
  }

  /// Removes every stored background photo.
  Future<void> clear() async {
    final dir = await getApplicationSupportDirectory();
    await _deleteOthers(dir, keep: null);
  }

  Future<void> _deleteOthers(Directory dir, {required String? keep}) async {
    await for (final entity in dir.list()) {
      if (entity is File &&
          p.basename(entity.path).startsWith(_prefix) &&
          entity.path != keep) {
        try {
          await entity.delete();
        } catch (_) {/* best effort */}
      }
    }
  }
}
