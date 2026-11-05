import 'shared_attachment.dart';

/// Content another app handed to us through the OS share sheet — the payload
/// behind "Share via Chat" in YouTube / Photos / Safari / a file manager.
///
/// Produced natively (Android `ACTION_SEND` / `ACTION_SEND_MULTIPLE`, iOS share
/// extension), pulled across `nanb.app/incoming_share`, and delivered into a
/// conversation the user picks on the share-target screen.
class IncomingShare {
  const IncomingShare({this.text = '', this.attachments = const []});

  /// Shared text — a URL from a browser/YouTube, a text selection, or the
  /// caption typed alongside media. Empty when only files were shared.
  final String text;

  /// Shared files, already copied somewhere this process can read.
  final List<SharedAttachment> attachments;

  /// Nothing to send — the native side handed over an empty or fully
  /// unreadable payload, so the share is dropped instead of opening a picker.
  bool get isEmpty => text.isEmpty && attachments.isEmpty;

  /// Number of messages this share will turn into, so the caller can tell a
  /// partial failure from a complete one. Text riding along as a single
  /// image/video's caption is NOT counted separately — it isn't its own
  /// message (see `ShareDispatcher`).
  int get messageCount {
    if (attachments.isEmpty) return text.isEmpty ? 0 : 1;
    if (text.isEmpty || _textRidesAsCaption) return attachments.length;
    return attachments.length + 1;
  }

  /// True when the text is folded into the lone attachment's caption rather
  /// than sent on its own. Only image/video carry a caption on the wire; a
  /// file bubble has no caption field, so text alongside a file stays its own
  /// message.
  bool get _textRidesAsCaption =>
      attachments.length == 1 && _captionable(attachments.first.mimeType);

  static bool _captionable(String mimeType) =>
      mimeType.startsWith('image/') || mimeType.startsWith('video/');

  /// Decodes the platform channel's `takePending` reply. Returns null when
  /// there was no pending share (the common case on every resume) or the
  /// payload carried nothing usable.
  static IncomingShare? tryParse(Object? raw) {
    if (raw is! Map<Object?, Object?>) return null;
    final text = raw['text'] as String? ?? '';
    final rawAttachments = raw['attachments'];
    final attachments = <SharedAttachment>[];
    if (rawAttachments is List<Object?>) {
      for (final entry in rawAttachments) {
        if (entry is! Map<Object?, Object?>) continue;
        final parsed = SharedAttachment.tryParse(entry);
        if (parsed != null) attachments.add(parsed);
      }
    }
    final share = IncomingShare(text: text.trim(), attachments: attachments);
    return share.isEmpty ? null : share;
  }
}
