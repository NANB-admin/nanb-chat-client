import 'dart:typed_data';

import 'media_pipeline.dart';

/// Fetches + decrypts profile avatars (encrypted media, same pipeline as chat
/// images) and caches the decrypted bytes by media id so the same avatar
/// rendered in many places (chat list, thread, settings) downloads once.
class AvatarLoader {
  AvatarLoader(this._media);

  final MediaPipeline _media;
  final Map<String, Uint8List> _cache = {};
  final Map<String, Future<Uint8List?>> _inflight = {};

  /// Decrypted bytes for [descriptor], or null if already cached-miss in flight.
  /// Returns null (not throws) on any download/decrypt failure — callers fall
  /// back to initials.
  Future<Uint8List?> load(MediaDescriptor descriptor) {
    final id = descriptor.mediaId;
    final cached = _cache[id];
    if (cached != null) return Future.value(cached);
    final inflight = _inflight[id];
    if (inflight != null) return inflight;
    final future = _media.download(descriptor).then<Uint8List?>((bytes) {
      final u = Uint8List.fromList(bytes);
      _cache[id] = u;
      _inflight.remove(id);
      return u;
    }).onError<Object>((_, _) {
      _inflight.remove(id);
      return null;
    });
    _inflight[id] = future;
    return future;
  }

  /// Synchronously-available cached bytes, if already loaded.
  Uint8List? cached(String mediaId) => _cache[mediaId];

  /// Drops a cached avatar (e.g. after the user changes their own).
  void evict(String mediaId) {
    _cache.remove(mediaId);
    _inflight.remove(mediaId);
  }
}
