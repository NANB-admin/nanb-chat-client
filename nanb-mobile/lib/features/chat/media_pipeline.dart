import 'dart:convert';

import '../../core/crypto/media_cipher.dart';
import '../../core/network/api_client.dart';
import '../../core/network/transient_retry.dart';
import 'models/message_kind.dart';

/// End-to-end encrypted media upload + download. The server (Plan 3) handles
/// presigned S3 URLs + 30-day retention; this pipeline owns the symmetric
/// encryption + integrity verification.
///
/// Send flow:
///   plaintext bytes → MediaCipher.encrypt → wire ciphertext + AES key
///   sha256(ciphertext) → POST /media/init → upload_url
///   PUT ciphertext to upload_url
///   return MediaDescriptor (media_id, key, sha256(plaintext), size, mime)
///
/// Receive flow:
///   POST /media/get(media_id) → download_url
///   GET download_url → wire ciphertext
///   MediaCipher.decrypt(ciphertext, key) → plaintext bytes
///   verify sha256(plaintext) matches descriptor
///   return plaintext bytes
class MediaPipeline {
  MediaPipeline(
    this._api, {
    Duration? Function()? ttlProvider,
    Future<void> Function(Duration)? delay,
  })  : _ttlProvider = ttlProvider,
        _retry = TransientRetry(delay: delay);
  final ApiClient _api;

  /// Shared with the text-send path so the two policies can't drift apart — see
  /// [TransientRetry]. `delay` is injectable so tests don't sleep the backoff.
  final TransientRetry _retry;

  /// Reads the user's message-retention preference at upload time so the
  /// server expires the S3 ciphertext on the same schedule (the server only
  /// honors ttl_seconds DOWNWARD from its 30-day ceiling). Null → server
  /// default.
  final Duration? Function()? _ttlProvider;

  /// Encrypt + upload `plaintext`. Returns the descriptor the sender
  /// embeds in the chat message. The descriptor's key is the AES key the
  /// recipient needs to decrypt the blob — wrap it inside the
  /// (ratchet-encrypted) message body, never send it in plaintext.
  Future<MediaDescriptor> upload({
    required MessageKind kind,
    required List<int> plaintext,
    required String mimeType,
    String? filename,
    List<int>? waveform,
    int? durationMs,
    // Conversation participant account IDs allowed to download this object
    // (the uploader is folded in server-side). Null/empty = legacy open access
    // — used for uploads with no bounded audience, e.g. profile avatars.
    List<String>? authorizedAccountIds,
  }) async {
    final encrypted = await MediaCipher.encrypt(plaintext);

    // Server uses sha256(ciphertext) as a content-addressable identifier on
    // the way in. The recipient verifies sha256(plaintext) on the way out
    // (different hash; we transport the plaintext digest in the descriptor).
    final cipherSha = await MediaCipher.sha256(encrypted.ciphertext);
    final plainSha = await MediaCipher.sha256(plaintext);

    final ttl = _ttlProvider?.call();
    // Retry both network legs on a TRANSIENT connection failure — notably the
    // built-in-Tor bootstrap window, where requests route through a fail-closed
    // sentinel and `connectionRefused` until the SOCKS port is up. Without this
    // a one-shot upload fired right after launch (setting an avatar, or
    // attaching media) fails until Tor finishes connecting. Real HTTP errors
    // (those carry a status code) are not retried.
    final init = await _retry.run(() => _api.initMediaUpload(
          sha256: cipherSha,
          sizeBytes: encrypted.ciphertext.length,
          mimeType: mimeType,
          ttlSeconds: ttl?.inSeconds,
          authorizedAccountIds: authorizedAccountIds,
        ));
    await _retry.run(() => _api.putBytesToUrl(
          url: init.uploadUrl,
          bytes: encrypted.ciphertext,
          mimeType: mimeType,
        ));

    return MediaDescriptor(
      kind: kind,
      mediaId: init.mediaId,
      key: encrypted.key,
      sha256: plainSha,
      sizeBytes: plaintext.length,
      mimeType: mimeType,
      filename: filename,
      waveform: waveform,
      durationMs: durationMs,
    );
  }

  /// Fetch + decrypt + integrity-check the media for `descriptor`. Throws
  /// `StateError` on hash mismatch (tampered or wrong descriptor).
  ///
  /// The fetch transport (server onion stream when on Tor, else
  /// presigned/CloudFront) is chosen inside the [ApiClient] — `getMedia`
  /// returns the right pointer and `getBytesFromUrl` fetches it — so this
  /// pipeline stays transport-agnostic.
  Future<List<int>> download(MediaDescriptor descriptor) async {
    final pointer = await _api.getMedia(descriptor.mediaId);
    final ciphertext = await _api.getBytesFromUrl(pointer.downloadUrl);
    final plaintext = await MediaCipher.decrypt(
      ciphertext: ciphertext,
      key: descriptor.key,
    );
    final actualSha = await MediaCipher.sha256(plaintext);
    if (!_listEq(actualSha, descriptor.sha256)) {
      throw StateError('media: sha256 mismatch — content tampered or descriptor corrupt');
    }
    return plaintext;
  }

  static bool _listEq(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// Pointer that gets embedded inside the (ratchet/MLS-encrypted) chat
/// message body. The recipient parses this back out via `fromJson`. The
/// `kind` discriminator drives bubble rendering on the recipient side.
class MediaDescriptor {
  const MediaDescriptor({
    required this.kind,
    required this.mediaId,
    required this.key,
    required this.sha256,
    required this.sizeBytes,
    required this.mimeType,
    this.filename,
    this.waveform,
    this.durationMs,
  });

  /// Drives `MessageKind` on the received `ChatMessage`. One of
  /// `image` / `voice` / `video` / `file`.
  final MessageKind kind;

  final String mediaId;
  final List<int> key;

  /// SHA-256 of the *plaintext* media bytes — verified after decrypt.
  final List<int> sha256;
  final int sizeBytes;
  final String mimeType;

  /// Original filename — only meaningful for `kind == MessageKind.file`.
  /// Voice / video / image leave this null.
  final String? filename;

  /// Per-recording amplitude bars for `kind == MessageKind.voice`. Each byte
  /// is a normalized 0..255 amplitude sample. Null for other kinds, and may
  /// be null on voice messages from peers running pre-waveform clients.
  final List<int>? waveform;

  /// Recording length in milliseconds for `kind == MessageKind.voice` —
  /// lets the receiving bubble label the note without downloading it. Null
  /// for other kinds and for senders predating the field.
  final int? durationMs;

  /// Compact JSON encoding for the wire body. Single-letter keys keep the
  /// post-ratchet message size small.
  String toJson() => jsonEncode({
        'k': kind.name,
        'mid': mediaId,
        'key': base64Encode(key),
        'sha': base64Encode(sha256),
        'size': sizeBytes,
        'mime': mimeType,
        if (filename != null) 'fn': filename,
        if (waveform != null) 'w': base64Encode(waveform!),
        if (durationMs != null) 'd': durationMs,
      });

  static MediaDescriptor fromJson(String raw) {
    final json = jsonDecode(raw) as Map<String, dynamic>;
    final wRaw = json['w'] as String?;
    return MediaDescriptor(
      kind: MessageKind.fromName(json['k'] as String?),
      mediaId: json['mid'] as String,
      key: base64Decode(json['key'] as String),
      sha256: base64Decode(json['sha'] as String),
      sizeBytes: json['size'] as int,
      mimeType: json['mime'] as String,
      filename: json['fn'] as String?,
      waveform: wRaw == null ? null : base64Decode(wRaw),
      durationMs: json['d'] as int?,
    );
  }

  /// True if `body` looks like a media descriptor (vs. a plain text
  /// message). Matches `{"k":"<one of image/voice/video/file>"...`.
  static bool looksLikeDescriptor(String body) {
    return body.startsWith('{"k":"image"') ||
        body.startsWith('{"k":"voice"') ||
        body.startsWith('{"k":"video"') ||
        body.startsWith('{"k":"file"');
  }
}
