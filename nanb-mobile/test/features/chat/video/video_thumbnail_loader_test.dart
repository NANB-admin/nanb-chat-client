import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/features/chat/services/temp_media_store.dart';
import 'package:nanb_chat/features/chat/video/video_thumbnail_generator.dart';
import 'package:nanb_chat/features/chat/video/video_thumbnail_loader.dart';
import 'package:path/path.dart' as p;

class _FakeGenerator implements VideoThumbnailGenerator {
  _FakeGenerator({this.thumbnail});

  Uint8List? thumbnail;
  String? lastPath;
  List<int>? bytesSeenAtGenerate;
  bool fileExistedAtGenerate = false;
  int calls = 0;

  @override
  Future<Uint8List?> generate(String videoPath) async {
    calls++;
    lastPath = videoPath;
    final f = File(videoPath);
    fileExistedAtGenerate = f.existsSync();
    if (fileExistedAtGenerate) {
      bytesSeenAtGenerate = await f.readAsBytes();
    }
    return thumbnail;
  }
}

void main() {
  group('VideoThumbnailLoader.generateFor', () {
    late Directory tempDir;
    late TempMediaStore store;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('nanb_thumb_test_');
      store = TempMediaStoreImpl(tempDirProvider: () async => tempDir);
    });

    tearDown(() async {
      if (tempDir.existsSync()) {
        await tempDir.delete(recursive: true);
      }
    });

    VideoThumbnailLoader loaderWith(VideoThumbnailGenerator gen) =>
        VideoThumbnailLoader(generator: gen, tempMediaStore: store);

    test('hands the video bytes to the generator via a temp file', () async {
      final gen = _FakeGenerator();
      await loaderWith(gen).generateFor(
        envelopeId: 'env-1',
        bytes: const [1, 2, 3, 4, 5],
      );
      expect(gen.fileExistedAtGenerate, isTrue);
      expect(gen.bytesSeenAtGenerate, const [1, 2, 3, 4, 5]);
    });

    test('deletes the decrypted temp file once the frame is decoded', () async {
      final gen = _FakeGenerator();
      await loaderWith(gen).generateFor(
        envelopeId: 'env-1',
        bytes: const [1, 2, 3],
      );
      expect(File(gen.lastPath!).existsSync(), isFalse);
      expect(tempDir.listSync().whereType<File>(), isEmpty);
    });

    test('deletes the temp file even when decoding returns no frame', () async {
      final gen = _FakeGenerator(thumbnail: null);
      await loaderWith(gen).generateFor(envelopeId: 'e', bytes: const [0]);
      expect(tempDir.listSync().whereType<File>(), isEmpty);
    });

    test('names the temp file under the sweepable TempMediaStore prefix',
        () async {
      final gen = _FakeGenerator();
      await loaderWith(gen).generateFor(envelopeId: 'env-42', bytes: const [0]);
      final name = p.basename(gen.lastPath!);
      expect(name, startsWith(TempMediaStoreImpl.filePrefix));
      expect(name, contains('env-42'));
    });

    test('forwards the generator output to the caller', () async {
      final expected = Uint8List.fromList(List.filled(8, 0xFF));
      final gen = _FakeGenerator(thumbnail: expected);
      final result =
          await loaderWith(gen).generateFor(envelopeId: 'env-1', bytes: const [0]);
      expect(result, expected);
    });

    test('returns null when the generator returns null', () async {
      final result = await loaderWith(_FakeGenerator(thumbnail: null))
          .generateFor(envelopeId: 'env-1', bytes: const [0]);
      expect(result, isNull);
    });

    test('uses different temp paths per envelopeId', () async {
      final gen = _FakeGenerator();
      final loader = loaderWith(gen);
      await loader.generateFor(envelopeId: 'a', bytes: const [0]);
      final pathA = gen.lastPath;
      await loader.generateFor(envelopeId: 'b', bytes: const [0]);
      final pathB = gen.lastPath;
      expect(pathA, isNot(equals(pathB)));
    });

    test('invokes the generator exactly once per call', () async {
      final gen = _FakeGenerator();
      await loaderWith(gen).generateFor(envelopeId: 'env-1', bytes: const [0]);
      expect(gen.calls, 1);
    });
  });
}
