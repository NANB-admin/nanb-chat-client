import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/features/chat/models/sticker.dart';

void main() {
  group('Sticker.mimeType', () {
    test('is image/png for a .png file', () {
      expect(const Sticker.file('/s/a.png').mimeType, 'image/png');
    });

    test('is image/webp for a .webp file', () {
      expect(const Sticker.file('/s/a.webp').mimeType, 'image/webp');
    });

    test('is image/gif for a .gif file', () {
      expect(const Sticker.file('/s/a.GIF').mimeType, 'image/gif');
    });

    test('is image/jpeg for a .jpg file', () {
      expect(const Sticker.file('/s/a.jpg').mimeType, 'image/jpeg');
    });

    test('falls back to image/png for an unknown extension', () {
      expect(const Sticker.file('/s/a.bin').mimeType, 'image/png');
    });
  });

  group('Sticker identity', () {
    test('two stickers with the same path are equal', () {
      expect(const Sticker.asset('assets/a.png'),
          const Sticker.asset('assets/a.png'));
    });

    test('a bundled sticker is not user-made', () {
      expect(const Sticker.asset('assets/a.png').isUserMade, isFalse);
    });

    test('a file sticker is user-made', () {
      expect(const Sticker.file('/s/a.png').isUserMade, isTrue);
    });
  });
}
