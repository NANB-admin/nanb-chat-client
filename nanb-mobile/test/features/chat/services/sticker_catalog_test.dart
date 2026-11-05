import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/features/chat/services/sticker_catalog.dart';

StickerCatalog _catalogOf(List<String> paths) =>
    StickerCatalog(listAssetPaths: () async => paths);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('groups sticker assets into one pack per folder', () async {
    final packs = await _catalogOf([
      'assets/stickers/faces/a.png',
      'assets/stickers/faces/b.png',
      'assets/stickers/fun/c.png',
    ]).bundledPacks();

    expect(packs.map((p) => p.id), ['faces', 'fun']);
    expect(packs.first.stickers.length, 2);
  });

  test('orders the shipped packs faces, reactions, fun', () async {
    final packs = await _catalogOf([
      'assets/stickers/fun/a.png',
      'assets/stickers/reactions/a.png',
      'assets/stickers/faces/a.png',
    ]).bundledPacks();

    expect(packs.map((p) => p.id), ['faces', 'reactions', 'fun']);
  });

  test('puts an unlisted pack after the shipped ones', () async {
    final packs = await _catalogOf([
      'assets/stickers/zebra/a.png',
      'assets/stickers/fun/a.png',
    ]).bundledPacks();

    expect(packs.map((p) => p.id), ['fun', 'zebra']);
  });

  test('derives a title from the folder name for an unlisted pack', () async {
    final packs = await _catalogOf([
      'assets/stickers/cute_animals/a.png',
    ]).bundledPacks();

    expect(packs.single.title, 'Cute Animals');
  });

  test('ignores non-image files', () async {
    final packs = await _catalogOf([
      'assets/stickers/faces/a.png',
      'assets/stickers/faces/notes.txt',
    ]).bundledPacks();

    expect(packs.single.stickers.length, 1);
  });

  test('ignores a loose file that is not inside a pack folder', () async {
    final packs = await _catalogOf([
      'assets/stickers/loose.png',
    ]).bundledPacks();

    expect(packs, isEmpty);
  });

  test('ignores assets outside the stickers folder', () async {
    final packs = await _catalogOf([
      'assets/icon/app_icon_foreground.png',
    ]).bundledPacks();

    expect(packs, isEmpty);
  });

  test('the real bundle ships three packs', () async {
    final packs = await StickerCatalog.fromBundle().bundledPacks();

    expect(packs.map((p) => p.id), ['faces', 'reactions', 'fun']);
  });

  test('every shipped pack holds 16 stickers', () async {
    final packs = await StickerCatalog.fromBundle().bundledPacks();

    expect(packs.map((p) => p.stickers.length), [16, 16, 16]);
  });
}
