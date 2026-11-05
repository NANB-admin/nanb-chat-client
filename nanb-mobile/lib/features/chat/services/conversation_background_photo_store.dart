import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Keeps a chat's custom background PHOTO in the app's private storage. The file
/// lives on this device only (it never syncs). Uses its own filename prefix so
/// the global `ChatBackgroundStore` never deletes it.
class ConversationBackgroundPhotoStore {
  const ConversationBackgroundPhotoStore();

  static String _prefix(String conversationId) =>
      'chat_bg_convo_${conversationId.hashCode.toUnsigned(32).toRadixString(16)}_';

  /// Copies [sourcePath] in under a fresh name, removes this chat's earlier
  /// photo, and returns the new path.
  Future<String> save(String conversationId, String sourcePath) async {
    final dir = await getApplicationSupportDirectory();
    final ext = p.extension(sourcePath).isEmpty ? '.jpg' : p.extension(sourcePath);
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final dest = p.join(dir.path, '${_prefix(conversationId)}$stamp$ext');
    await File(sourcePath).copy(dest);
    await _deleteOthers(dir, conversationId, keep: dest);
    return dest;
  }

  /// Removes this chat's stored photo, if any.
  Future<void> clear(String conversationId) async {
    final dir = await getApplicationSupportDirectory();
    await _deleteOthers(dir, conversationId, keep: null);
  }

  Future<void> _deleteOthers(Directory dir, String conversationId,
      {required String? keep}) async {
    final prefix = _prefix(conversationId);
    await for (final entity in dir.list()) {
      if (entity is File &&
          p.basename(entity.path).startsWith(prefix) &&
          entity.path != keep) {
        try {
          await entity.delete();
        } catch (_) {/* best effort */}
      }
    }
  }
}
