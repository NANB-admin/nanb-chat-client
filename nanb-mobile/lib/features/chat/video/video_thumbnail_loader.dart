import 'dart:io';
import 'dart:typed_data';

import '../services/temp_media_store.dart';
import 'video_thumbnail_generator.dart';

/// Writes decrypted video bytes to a temp file then asks
/// [VideoThumbnailGenerator] to decode the first frame. Decoupled from the
/// bubble widget so unit tests can verify the orchestration without spinning
/// up Flutter widgets or the native plugin.
class VideoThumbnailLoader {
  VideoThumbnailLoader({
    required VideoThumbnailGenerator generator,
    TempMediaStore? tempMediaStore,
  })  : _generator = generator,
        _tempMediaStore = tempMediaStore ?? TempMediaStoreImpl();

  final VideoThumbnailGenerator _generator;
  final TempMediaStore _tempMediaStore;

  /// Persists [bytes] to a temp file named with [envelopeId] (so concurrent
  /// thumbnails for different messages don't clobber each other), decodes a
  /// frame, then DELETES the temp file — the decoded frame lives in memory, so
  /// the decrypted video has no further consumer and must not linger on disk
  /// (a "deleted" video would otherwise leave plaintext in the temp dir). A
  /// straggler from a crash between the write and the delete is reclaimed by
  /// [TempMediaStore.sweepAll]. Returns null if the generator can't decode a
  /// frame (corrupt video, unsupported codec) — caller renders a fallback.
  Future<Uint8List?> generateFor({
    required String envelopeId,
    required List<int> bytes,
  }) async {
    final path = await _tempMediaStore.allocate(
      envelopeId: envelopeId,
      label: 'vthumb.mp4',
    );
    final file = File(path);
    await file.writeAsBytes(bytes, flush: true);
    try {
      return await _generator.generate(path);
    } finally {
      try {
        await file.delete();
      } catch (_) {/* best-effort; sweepAll reclaims a straggler */}
    }
  }
}
