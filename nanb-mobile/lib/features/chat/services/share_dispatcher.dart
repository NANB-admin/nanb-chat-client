import 'dart:io';

import '../../../core/models/incoming_share.dart';
import '../../../core/models/shared_attachment.dart';
import 'share_send_target.dart';

/// Loads the bytes of one OS-supplied share temp file, or null when it can't
/// be sent (missing, unreadable, or over the server's media ceiling).
///
/// The default implementation also DELETES the temp copy once read: those
/// copies are plaintext files the OS handed us outside our encrypted store, so
/// they shouldn't outlive the send. Discarding after the read is safe because
/// the send path has already taken the bytes into memory and staged them
/// (encrypted) for retry — see `PendingUploadStaging`.
typedef SharedFileLoader = Future<List<int>?> Function(String path);

/// Delivers an [IncomingShare] into one conversation through the ordinary
/// end-to-end-encrypted send paths.
///
/// Everything shared from another app funnels through here, so a share is
/// encrypted exactly like a message composed in-app — the share sheet is only
/// a different way of choosing the content, never a different way of sending
/// it.
class ShareDispatcher {
  ShareDispatcher(this._target, {SharedFileLoader? loadFile})
      : _loadFile = loadFile ?? _readAndDiscard;

  final ShareSendTarget _target;
  final SharedFileLoader _loadFile;

  /// The server caps encrypted media at `NANB_MEDIA_MAX_SIZE_MB=100`; matches
  /// the in-thread attach flow so a share can't fail late in the upload.
  static const int maxAttachmentBytes = 100 * 1024 * 1024;

  /// Sends [share] into [conversationId]. Returns how many messages were
  /// actually sent, which the caller compares against
  /// [IncomingShare.messageCount] to report a partial failure.
  ///
  /// Attachments are sent in order and independently: one unreadable or
  /// oversize file is skipped, never aborting the rest of the share.
  Future<int> deliver({
    required IncomingShare share,
    required String conversationId,
    required String myDeviceId,
  }) async {
    final perConversation = await deliverToAll(
      share: share,
      conversationIds: [conversationId],
      myDeviceId: myDeviceId,
    );
    return perConversation[conversationId] ?? 0;
  }

  /// Sends [share] into every conversation in [conversationIds].
  ///
  /// Each attachment is read (and its OS temp copy deleted) exactly ONCE up
  /// front, then reused for every recipient — reading per recipient would find
  /// the file already discarded for all but the first. Returns messages sent
  /// per conversation id.
  Future<Map<String, int>> deliverToAll({
    required IncomingShare share,
    required List<String> conversationIds,
    required String myDeviceId,
  }) async {
    final loaded = <_LoadedAttachment>[
      for (final a in share.attachments)
        _LoadedAttachment(a, await _loadFile(a.path)),
    ];
    final result = <String, int>{};
    for (final id in conversationIds) {
      result[id] = await _deliverLoaded(
        share: share,
        loaded: loaded,
        conversationId: id,
        myDeviceId: myDeviceId,
      );
    }
    return result;
  }

  Future<int> _deliverLoaded({
    required IncomingShare share,
    required List<_LoadedAttachment> loaded,
    required String conversationId,
    required String myDeviceId,
  }) async {
    var sent = 0;
    // A single image/video carries the shared text as its caption — the shape
    // the user expects from "share this photo with a note". Anything else
    // (multiple files, a document, text alone) sends the text as its own
    // message first, since only image/video have a caption on the wire.
    final caption = _captionFor(share);
    if (share.text.isNotEmpty && caption.isEmpty) {
      await _target.sendMessage(
        conversationId: conversationId,
        myDeviceId: myDeviceId,
        text: share.text,
      );
      sent++;
    }
    for (final item in loaded) {
      if (await _sendAttachment(
        attachment: item.attachment,
        bytes: item.bytes,
        caption: caption,
        conversationId: conversationId,
        myDeviceId: myDeviceId,
      )) {
        sent++;
      }
    }
    return sent;
  }

  /// The text to fold into a lone image/video's caption, or empty when the
  /// text should be its own message.
  static String _captionFor(IncomingShare share) {
    if (share.text.isEmpty || share.attachments.length != 1) return '';
    final mime = share.attachments.first.mimeType;
    final captionable =
        mime.startsWith('image/') || mime.startsWith('video/');
    return captionable ? share.text : '';
  }

  /// Sends one attachment down the send path its MIME type calls for. Returns
  /// false when the bytes couldn't be loaded, so the caller can count it as
  /// skipped.
  Future<bool> _sendAttachment({
    required SharedAttachment attachment,
    required List<int>? bytes,
    required String caption,
    required String conversationId,
    required String myDeviceId,
  }) async {
    if (bytes == null || bytes.isEmpty) return false;
    final mime = attachment.mimeType;
    if (mime.startsWith('image/')) {
      await _target.sendImage(
        conversationId: conversationId,
        myDeviceId: myDeviceId,
        imageBytes: bytes,
        mimeType: mime,
        caption: caption,
      );
      return true;
    }
    if (mime.startsWith('video/')) {
      await _target.sendVideo(
        conversationId: conversationId,
        myDeviceId: myDeviceId,
        videoBytes: bytes,
        mimeType: mime,
        caption: caption,
      );
      return true;
    }
    // Everything else — documents, archives, and audio FILES. Audio goes here
    // rather than to `sendVoice`: a shared music/podcast file is not a voice
    // note (no waveform, no recording duration) and renders correctly as a
    // file bubble with its original name.
    await _target.sendFile(
      conversationId: conversationId,
      myDeviceId: myDeviceId,
      fileBytes: bytes,
      mimeType: mime,
      filename: attachment.filename,
    );
    return true;
  }

  /// Default [SharedFileLoader]: size-checks from metadata BEFORE reading (so
  /// an oversize file is never pulled into memory), reads off the UI thread via
  /// dart:io's worker pool, then deletes the OS-supplied plaintext copy.
  static Future<List<int>?> _readAndDiscard(String path) async {
    final file = File(path);
    try {
      if (!await file.exists()) return null;
      if (await file.length() > maxAttachmentBytes) {
        await _discard(file);
        return null;
      }
      final bytes = await file.readAsBytes();
      await _discard(file);
      return bytes;
    } catch (_) {
      return null;
    }
  }

  static Future<void> _discard(File file) async {
    try {
      await file.delete();
    } catch (_) {
      // Best-effort: the OS reclaims the cache / App Group inbox anyway, and a
      // failed cleanup must not lose the share.
    }
  }
}

/// An attachment together with its bytes, read once and shared by every
/// recipient of a multi-target share. Null bytes = unreadable / oversize.
class _LoadedAttachment {
  const _LoadedAttachment(this.attachment, this.bytes);

  final SharedAttachment attachment;
  final List<int>? bytes;
}
