import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/features/chat/models/sticker_image.dart';
import 'package:nanb_chat/features/chat/services/user_sticker_store.dart';

void main() {
  late Directory root;
  late UserStickerStore store;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('sticker_store_test');
    // A subfolder that doesn't exist yet, as on a fresh install.
    store = UserStickerStore(
      directory: () async => Directory('${root.path}/stickers'),
    );
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  const png = StickerImage(bytes: [1, 2, 3], mimeType: 'image/png');
  const other = StickerImage(bytes: [9, 9, 9], mimeType: 'image/png');

  test('lists nothing before any sticker is added', () async {
    expect(await store.list(), isEmpty);
  });

  test('an added sticker appears in the list', () async {
    final added = await store.add(png);

    expect(await store.list(), [added]);
  });

  test('stores the exact bytes it was given', () async {
    final added = await store.add(png);

    expect(await File(added.filePath!).readAsBytes(), [1, 2, 3]);
  });

  test('names the file with an extension matching the mime type', () async {
    final added = await store.add(
      const StickerImage(bytes: [1], mimeType: 'image/webp'),
    );

    expect(added.filePath, endsWith('.webp'));
  });

  test('adding the same image twice keeps a single sticker', () async {
    await store.add(png);
    await store.add(png);

    expect((await store.list()).length, 1);
  });

  test('lists the most recently added sticker first', () async {
    final first = await store.add(png);
    // Filesystem mtime can be coarse; push the first one clearly into the past.
    await File(first.filePath!)
        .setLastModified(DateTime.now().subtract(const Duration(minutes: 5)));
    final second = await store.add(other);

    expect(await store.list(), [second, first]);
  });

  test('re-adding an existing sticker moves it to the front', () async {
    final first = await store.add(png);
    await File(first.filePath!)
        .setLastModified(DateTime.now().subtract(const Duration(minutes: 10)));
    final second = await store.add(other);
    await File(second.filePath!)
        .setLastModified(DateTime.now().subtract(const Duration(minutes: 5)));

    await store.add(png);

    expect((await store.list()).first, first);
  });

  test('remove deletes the sticker', () async {
    final added = await store.add(png);

    await store.remove(added);

    expect(await store.list(), isEmpty);
  });

  test('clear deletes every sticker', () async {
    await store.add(png);
    await store.add(other);

    await store.clear();

    expect(await store.list(), isEmpty);
  });

  test('clear is a no-op when nothing was ever saved', () async {
    await store.clear();

    expect(await store.list(), isEmpty);
  });
}
