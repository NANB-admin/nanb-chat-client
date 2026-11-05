import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/features/chat/models/chat_message.dart';
import 'package:nanb_chat/features/chat/models/message_kind.dart';
import 'package:nanb_chat/features/chat/services/sticker_marker.dart';

ChatMessage _message({required MessageKind kind, String? filename}) =>
    ChatMessage(
      envelopeId: 'e1',
      conversationId: 'c1',
      senderDeviceId: 'd1',
      body: '',
      serverTs: DateTime.utc(2026, 1, 1),
      kind: kind,
      mine: false,
      mediaFilename: filename,
    );

void main() {
  group('StickerMarker.filenameFor', () {
    test('uses .png for image/png', () {
      expect(StickerMarker.filenameFor('image/png'), 'sticker.png');
    });

    test('uses .webp for image/webp', () {
      expect(StickerMarker.filenameFor('image/webp'), 'sticker.webp');
    });

    test('uses .gif for image/gif', () {
      expect(StickerMarker.filenameFor('image/gif'), 'sticker.gif');
    });

    test('uses .jpg for image/jpeg', () {
      expect(StickerMarker.filenameFor('image/jpeg'), 'sticker.jpg');
    });
  });

  group('StickerMarker.isSticker', () {
    test('is true for an image carrying a sticker filename', () {
      expect(
        StickerMarker.isSticker(
            _message(kind: MessageKind.image, filename: 'sticker.webp')),
        isTrue,
      );
    });

    test('is false for an image with no filename', () {
      expect(StickerMarker.isSticker(_message(kind: MessageKind.image)),
          isFalse);
    });

    test('is false for an image with an unrelated filename', () {
      expect(
        StickerMarker.isSticker(
            _message(kind: MessageKind.image, filename: 'holiday.jpg')),
        isFalse,
      );
    });

    test('is false for a non-image carrying a sticker filename', () {
      expect(
        StickerMarker.isSticker(
            _message(kind: MessageKind.file, filename: 'sticker.png')),
        isFalse,
      );
    });
  });
}
