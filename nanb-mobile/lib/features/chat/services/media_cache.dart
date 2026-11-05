import 'dart:collection';
import 'dart:typed_data';

import '../media_pipeline.dart';
import '../models/chat_message.dart';
import '../models/message_kind.dart';
import '../video/video_thumbnail_loader.dart';

/// In-memory, byte-bounded LRU cache + lazy fetcher for decrypted media bytes
/// and decoded video thumbnails, with concurrent-call dedupe. Lifted out of
/// `ConversationsNotifier`: it's display-layer (a bubble lazy-fetches via
/// [MediaPipeline] / [VideoThumbnailLoader] on access) and independent of the
/// send/receive ratchet. Lost on restart.
class MediaCache {
  MediaCache({
    required MediaPipeline media,
    required VideoThumbnailLoader thumbnailLoader,
  })  : _media = media,
        _thumbnailLoader = thumbnailLoader;

  final MediaPipeline _media;
  final VideoThumbnailLoader _thumbnailLoader;

  /// Max decrypted media bytes held in memory before LRU eviction.
  static const int maxBytes = 50 * 1024 * 1024;

  /// Max decoded-thumbnail bytes held in memory before LRU eviction.
  static const int thumbnailMaxBytes = 5 * 1024 * 1024;

  final LinkedHashMap<String, List<int>> _bytes =
      LinkedHashMap<String, List<int>>();
  int _bytesTotal = 0;
  final LinkedHashMap<String, Uint8List> _thumbs =
      LinkedHashMap<String, Uint8List>();
  int _thumbsTotal = 0;
  final Map<String, Future<List<int>>> _inflight = {};
  final Map<String, Future<Uint8List?>> _inflightThumbs = {};

  /// Synchronous cache peek by key (envelope OR outbox id). No LRU bump — lets
  /// a freshly-built bubble paint already-decrypted bytes on its first frame.
  List<int>? cached(String key) => _bytes[key];

  /// Synchronous thumbnail-cache peek by key.
  Uint8List? cachedThumbnail(String key) => _thumbs[key];

  /// Returns the decrypted media bytes for [m], fetching + decrypting them if
  /// not already cached. Null when [m] isn't a media kind or the descriptor is
  /// missing fields. Concurrent calls for the same envelope dedupe.
  Future<List<int>?> bytesFor(ChatMessage m) {
    final cachedBytes = _bytes[m.envelopeId];
    if (cachedBytes != null) {
      // LRU bump: re-insert to move to the back of the access order.
      _bytes.remove(m.envelopeId);
      _bytes[m.envelopeId] = cachedBytes;
      return Future.value(cachedBytes);
    }
    if (m.kind == MessageKind.text) return Future.value(null);
    final id = m.mediaId,
        key = m.mediaKey,
        sha = m.mediaSha256,
        mime = m.mediaMime,
        size = m.mediaSize;
    if (id == null ||
        key == null ||
        sha == null ||
        mime == null ||
        size == null) {
      return Future.value(null);
    }
    final inflight = _inflight[m.envelopeId];
    if (inflight != null) return inflight;
    final descriptor = MediaDescriptor(
      kind: m.kind,
      mediaId: id,
      key: key,
      sha256: sha,
      sizeBytes: size,
      mimeType: mime,
    );
    final future = _media.download(descriptor).then((bytes) {
      put(m.envelopeId, bytes);
      _inflight.remove(m.envelopeId);
      return bytes;
    }).onError<Object>((e, st) {
      _inflight.remove(m.envelopeId);
      throw e;
    });
    _inflight[m.envelopeId] = future;
    return future;
  }

  /// Returns the decoded first-frame JPEG bytes for a video message, fetching +
  /// decoding on first access and caching the result. Null for non-video kinds,
  /// missing descriptors, or when the decoder can't extract a frame. Concurrent
  /// calls for the same envelope dedupe.
  Future<Uint8List?> thumbnailFor(ChatMessage m) {
    if (m.kind != MessageKind.video) return Future.value(null);
    final cachedThumb = _thumbs[m.envelopeId];
    if (cachedThumb != null) {
      // LRU bump.
      _thumbs.remove(m.envelopeId);
      _thumbs[m.envelopeId] = cachedThumb;
      return Future.value(cachedThumb);
    }
    final inflight = _inflightThumbs[m.envelopeId];
    if (inflight != null) return inflight;
    final future = _loadThumbnail(m);
    _inflightThumbs[m.envelopeId] = future;
    return future;
  }

  Future<Uint8List?> _loadThumbnail(ChatMessage m) async {
    try {
      final bytes = await bytesFor(m);
      if (bytes == null) return null;
      final thumb = await _thumbnailLoader.generateFor(
        envelopeId: m.envelopeId,
        bytes: bytes,
      );
      if (thumb == null) return null;
      putThumbnail(m.envelopeId, thumb);
      return thumb;
    } finally {
      _inflightThumbs.remove(m.envelopeId);
    }
  }

  /// Insert/replace [bytes] under [key], LRU-evicting oldest entries past the
  /// byte budget.
  void put(String key, List<int> bytes) {
    final existing = _bytes.remove(key);
    if (existing != null) _bytesTotal -= existing.length;
    _bytes[key] = bytes;
    _bytesTotal += bytes.length;
    while (_bytesTotal > maxBytes && _bytes.isNotEmpty) {
      final oldestKey = _bytes.keys.first;
      final oldestBytes = _bytes.remove(oldestKey)!;
      _bytesTotal -= oldestBytes.length;
    }
  }

  /// Insert/replace a [thumbnail] under [key], LRU-evicting past the budget.
  void putThumbnail(String key, Uint8List thumbnail) {
    final existing = _thumbs.remove(key);
    if (existing != null) _thumbsTotal -= existing.length;
    _thumbs[key] = thumbnail;
    _thumbsTotal += thumbnail.length;
    while (_thumbsTotal > thumbnailMaxBytes && _thumbs.isNotEmpty) {
      final oldestKey = _thumbs.keys.first;
      final oldestBytes = _thumbs.remove(oldestKey)!;
      _thumbsTotal -= oldestBytes.length;
    }
  }

  /// Drop the cached bytes for [key] (e.g. on unsend/delete or the
  /// optimistic→acked id swap).
  void evict(String key) {
    final existing = _bytes.remove(key);
    if (existing != null) _bytesTotal -= existing.length;
  }

  /// Drop the cached thumbnail for [key].
  void evictThumbnail(String key) {
    final existing = _thumbs.remove(key);
    if (existing != null) _thumbsTotal -= existing.length;
  }

  /// Drop everything (bytes + thumbnails + in-flight dedupe maps). Used on
  /// sign-out / local-state wipe.
  void clear() {
    _bytes.clear();
    _bytesTotal = 0;
    _inflight.clear();
    _thumbs.clear();
    _thumbsTotal = 0;
    _inflightThumbs.clear();
  }
}
