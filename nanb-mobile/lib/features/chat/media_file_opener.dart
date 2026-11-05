import 'dart:io';

import 'file_opener.dart';
import 'services/temp_media_store.dart';

/// Writes decrypted attachment bytes to a temp file with the original
/// (sanitized) filename, then asks the OS to open it via [FileOpener].
///
/// Filename sanitation matters: the name comes from the peer-supplied media
/// descriptor over the wire. An attacker-controlled filename like
/// `../../etc/passwd` could traverse outside the temp dir on disk, and
/// shell-metachar names confuse some file pickers. The sanitizer is the
/// single chokepoint enforcing safety.
class MediaFileOpener {
  MediaFileOpener({
    required FileOpener opener,
    TempMediaStore? tempMediaStore,
  })  : _opener = opener,
        _tempMediaStore = tempMediaStore ?? TempMediaStoreImpl();

  final FileOpener _opener;
  final TempMediaStore _tempMediaStore;

  /// Max filename length after sanitation. Most filesystems cap at 255 bytes;
  /// 180 leaves room for the sweepable `TempMediaStore` prefix + envelope tag
  /// that [writeAndOpen] prepends.
  static const int maxFilenameLength = 180;

  /// Strips path separators, shell-metachars, control chars, and trims length
  /// to [maxFilenameLength]. Falls back to `attachment` for inputs that
  /// reduce to empty / `.` / `..` so we never end up with a nameless file.
  static String sanitizeFilename(String raw) {
    if (raw.isEmpty) return 'attachment';
    var s = raw;
    // Path separators + Windows-reserved + shell meta + null/control bytes.
    s = s.replaceAll(RegExp(r'[\\\/:\*\?"<>\|]'), '_');
    s = s.replaceAll(RegExp(r'[\x00-\x1F\x7F]'), '_');
    s = s.trim();
    if (s.isEmpty || s == '.' || s == '..') return 'attachment';
    if (s.length > maxFilenameLength) {
      s = s.substring(0, maxFilenameLength);
    }
    return s;
  }

  /// Writes [bytes] to a temp file tagged with [envelopeId] (via
  /// [TempMediaStore]) and asks the OS to open it. The envelope tag prevents
  /// collisions when two messages share a filename AND lets the decrypted copy
  /// be reclaimed when the message is deleted/expires — the file can't be
  /// deleted here because the external viewer app still needs to read it.
  Future<FileOpenResult> writeAndOpen({
    required String envelopeId,
    required String filename,
    required List<int> bytes,
  }) async {
    final safe = sanitizeFilename(filename);
    final path = await _tempMediaStore.allocate(
      envelopeId: envelopeId,
      label: safe,
    );
    final file = File(path);
    await file.writeAsBytes(bytes, flush: true);
    return _opener.open(path);
  }
}
