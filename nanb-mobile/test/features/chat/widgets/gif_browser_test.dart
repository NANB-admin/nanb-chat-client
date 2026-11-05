import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/core/gif/gif_client.dart';
import 'package:nanb_chat/core/gif/gif_result.dart';
import 'package:nanb_chat/features/chat/widgets/gif_browser.dart';

/// A 1x1 transparent PNG — valid bytes so `Image.memory` decodes cleanly.
final _tinyPng = <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
  0x89, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41,
  0x54, 0x78, 0x9C, 0x62, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
  0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
  0x42, 0x60, 0x82,
];

/// Records which URLs the picker asks the proxy client to fetch.
class _RecordingGifClient extends GifClient {
  _RecordingGifClient(this.results) : super(baseUrl: 'http://test');

  final List<GifResult> results;
  final List<String> downloaded = [];

  @override
  Future<List<GifResult>> search(String query, {int limit = 30}) async => results;

  @override
  Future<List<GifResult>> trending({int limit = 30}) async => results;

  @override
  Future<List<int>> downloadBytes(String mediaUrl) async {
    downloaded.add(mediaUrl);
    return _tinyPng;
  }

  @override
  void close() {}
}

void main() {
  testWidgets(
    'thumbnails are fetched through the proxy client, never the provider CDN '
    'directly (Image.network would bypass Tor and leak the real IP)',
    (tester) async {
      const previewUrl = 'https://media.tenor.com/abc/preview.gif';
      final fake = _RecordingGifClient(const [
        GifResult(
          id: 'abc',
          previewUrl: previewUrl,
          sendUrl: 'https://media.tenor.com/abc/send.gif',
          width: 100,
          height: 100,
        ),
      ]);

      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: GifBrowser(onSelected: (_) {}, client: fake),
            ),
          ),
        ),
      );
      // Resolve _init → _load(search) → setState(results) → grid build → _thumb.
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }

      // The picker pulled the preview through the proxy client...
      expect(fake.downloaded, contains(previewUrl));
      // ...and renders from memory — no Image.network in the tree.
      final images = tester.widgetList<Image>(find.byType(Image));
      for (final img in images) {
        expect(img.image, isA<MemoryImage>());
      }
    },
  );
}
