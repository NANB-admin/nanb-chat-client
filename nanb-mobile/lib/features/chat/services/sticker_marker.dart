import '../models/chat_message.dart';
import '../models/message_kind.dart';

/// How a sticker is told apart from an ordinary photo on the wire.
///
/// A sticker is an `image` message whose media descriptor carries a
/// `sticker.<ext>` filename. Images never otherwise set a filename, so this
/// needs no new message kind, no wire-format change and no DB column. An older
/// client that doesn't know about stickers simply renders it as a normal image.
class StickerMarker {
  StickerMarker._();

  static const _stem = 'sticker';

  /// The descriptor filename a sticker of [mimeType] is sent with.
  static String filenameFor(String mimeType) {
    switch (mimeType) {
      case 'image/webp':
        return '$_stem.webp';
      case 'image/gif':
        return '$_stem.gif';
      case 'image/jpeg':
        return '$_stem.jpg';
      default:
        return '$_stem.png';
    }
  }

  static bool isSticker(ChatMessage m) =>
      m.kind == MessageKind.image &&
      (m.mediaFilename?.startsWith('$_stem.') ?? false);
}
