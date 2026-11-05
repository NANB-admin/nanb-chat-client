import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/features/chat/models/sticker_image.dart';
import 'package:nanb_chat/features/chat/services/sticker_collector.dart';
import 'package:nanb_chat/features/chat/services/sticker_normalizer.dart';
import 'package:nanb_chat/features/chat/services/user_sticker_store.dart';

/// Normalizer stand-in: returns whatever the test configured, ignoring input.
class _FakeNormalizer implements StickerNormalizer {
  _FakeNormalizer(this.result);

  final StickerImage? result;

  @override
  Future<StickerImage?> normalize(List<int> bytes, String mimeType) async =>
      result;
}

void main() {
  late Directory root;
  late UserStickerStore store;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('sticker_collector_test');
    store = UserStickerStore(directory: () async => root);
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('saves the normalized image, not the original bytes', () async {
    final collector = StickerCollector(
      normalizer: _FakeNormalizer(
        const StickerImage(bytes: [7, 7], mimeType: 'image/png'),
      ),
      store: store,
    );

    final saved = await collector.addFromBytes([1, 2, 3, 4, 5], 'image/jpeg');

    expect(await File(saved!.filePath!).readAsBytes(), [7, 7]);
  });

  test('returns null for an image that cannot be decoded', () async {
    final collector = StickerCollector(
      normalizer: _FakeNormalizer(null),
      store: store,
    );

    expect(await collector.addFromBytes([1], 'image/png'), isNull);
  });

  test('saves nothing for an image that cannot be decoded', () async {
    final collector = StickerCollector(
      normalizer: _FakeNormalizer(null),
      store: store,
    );

    await collector.addFromBytes([1], 'image/png');

    expect(await store.list(), isEmpty);
  });
}
