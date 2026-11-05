import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/features/chat/models/sticker.dart';
import 'package:nanb_chat/features/chat/models/sticker_image.dart';
import 'package:nanb_chat/features/chat/models/sticker_import_file.dart';
import 'package:nanb_chat/features/chat/services/sticker_collector.dart';
import 'package:nanb_chat/features/chat/services/sticker_importer.dart';
import 'package:nanb_chat/features/chat/services/sticker_normalizer.dart';
import 'package:nanb_chat/features/chat/services/user_sticker_store.dart';

class _AcceptAllNormalizer extends StickerNormalizer {
  const _AcceptAllNormalizer();

  @override
  Future<StickerImage?> normalize(List<int> bytes, String mimeType) async =>
      bytes.isEmpty ? null : StickerImage(bytes: bytes, mimeType: mimeType);
}

class _RecordingStore extends UserStickerStore {
  final List<String> mimes = [];

  @override
  Future<Sticker> add(StickerImage image) async {
    mimes.add(image.mimeType);
    return Sticker.file('/x/${mimes.length}');
  }
}

Uint8List _zip(Map<String, List<int>> entries) {
  final archive = Archive();
  entries.forEach((n, b) => archive.addFile(ArchiveFile(n, b.length, b)));
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

StickerImportFile _f(String name, List<int> b) =>
    StickerImportFile(name: name, bytes: Uint8List.fromList(b));

void main() {
  late _RecordingStore store;
  late StickerImporter importer;

  setUp(() {
    store = _RecordingStore();
    importer = StickerImporter(
        StickerCollector(normalizer: const _AcceptAllNormalizer(), store: store));
  });

  test('imports a loose webp image with the webp mime type', () async {
    final r = await importer.import([_f('a.webp', [1, 2])]);
    expect(r.added, 1);
    expect(store.mimes, ['image/webp']);
  });

  test('skips files that are not images', () async {
    final r = await importer.import([_f('notes.txt', [1])]);
    expect((r.added, r.skipped), (0, 1));
  });

  test('unpacks every image from a .wastickers bundle', () async {
    final zip = _zip({'1.webp': [1], '2.webp': [2], 'author.txt': utf8.encode('x')});
    final r = await importer.import([_f('pack.wastickers', zip)]);
    expect((r.added, r.skipped), (2, 1));
  });

  test('ignores the tray icon of a bundle', () async {
    final zip = _zip({'tray.png': [1], '1.webp': [2]});
    final r = await importer.import([_f('pack.zip', zip)]);
    expect(r.added, 1);
  });

  test('counts a corrupt bundle as skipped', () async {
    final r = await importer.import([_f('bad.wastickers', [1, 2, 3])]);
    expect((r.added, r.skipped), (0, 1));
  });

  test('stops at the per-import sticker cap', () async {
    final files = [
      for (var i = 0; i < StickerImporter.maxStickers + 5; i++)
        _f('$i.png', [1])
    ];
    final r = await importer.import(files);
    expect(r.added, StickerImporter.maxStickers);
  });
}
