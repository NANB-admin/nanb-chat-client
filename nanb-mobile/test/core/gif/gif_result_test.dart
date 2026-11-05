import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/core/gif/gif_result.dart';

void main() {
  group('GifResult.fromJson', () {
    test('parses preview + send urls and dimensions', () {
      final gif = GifResult.fromJson({
        'id': 'abc123',
        'previewUrl': 'https://media.tenor.com/preview.gif',
        'sendUrl': 'https://media.tenor.com/send.gif',
        'width': 200,
        'height': 150,
      });

      expect(gif, isNotNull);
      expect(gif!.id, 'abc123');
      expect(gif.previewUrl, 'https://media.tenor.com/preview.gif');
      expect(gif.sendUrl, 'https://media.tenor.com/send.gif');
      expect(gif.aspectRatio, closeTo(200 / 150, 0.001));
    });

    test('parses dimensions supplied as strings', () {
      final gif = GifResult.fromJson({
        'id': 'x',
        'previewUrl': 'https://m/p.gif',
        'sendUrl': 'https://m/s.gif',
        'width': '100',
        'height': '50',
      });

      expect(gif, isNotNull);
      expect(gif!.aspectRatio, closeTo(100 / 50, 0.001));
    });

    test('returns null when id or a rendition url is missing/malformed', () {
      expect(
        GifResult.fromJson({
          'previewUrl': 'https://m/p.gif',
          'sendUrl': 'https://m/s.gif',
        }),
        isNull,
        reason: 'no id',
      );
      expect(
        GifResult.fromJson({'id': 'x', 'sendUrl': 'https://m/s.gif'}),
        isNull,
        reason: 'no previewUrl',
      );
      expect(
        GifResult.fromJson({'id': 'x', 'previewUrl': 'https://m/p.gif'}),
        isNull,
        reason: 'no sendUrl',
      );
    });

    test('defaults aspect ratio to 1 when dimensions are missing', () {
      final gif = GifResult.fromJson({
        'id': 'x',
        'previewUrl': 'https://m/p.gif',
        'sendUrl': 'https://m/s.gif',
      });
      expect(gif, isNotNull);
      expect(gif!.aspectRatio, 1);
    });
  });
}
