import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/features/chat/services/temp_media_store.dart';
import 'package:path/path.dart' as p;

void main() {
  group('TempMediaStoreImpl', () {
    late Directory tempDir;
    late TempMediaStoreImpl store;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('nanb_tmpmedia_test_');
      store = TempMediaStoreImpl(tempDirProvider: () async => tempDir);
    });

    tearDown(() async {
      if (tempDir.existsSync()) await tempDir.delete(recursive: true);
    });

    Future<File> write(String envelopeId, String label, List<int> bytes) async {
      final path = await store.allocate(envelopeId: envelopeId, label: label);
      final f = File(path);
      await f.writeAsBytes(bytes, flush: true);
      return f;
    }

    test('allocate returns a path directly under the temp dir', () async {
      final path = await store.allocate(envelopeId: 'e1', label: 'video.mp4');
      expect(p.dirname(path), tempDir.path);
    });

    test('allocate names the file under the sweepable prefix with the tag',
        () async {
      final path = await store.allocate(envelopeId: 'e1', label: 'video.mp4');
      final name = p.basename(path);
      expect(name, startsWith(TempMediaStoreImpl.filePrefix));
      expect(name, contains('e1'));
      expect(name, endsWith('video.mp4'));
    });

    test('deleteForEnvelope removes that envelope\'s file', () async {
      final f = await write('e1', 'video.mp4', const [1, 2, 3]);
      await store.deleteForEnvelope('e1');
      expect(f.existsSync(), isFalse);
    });

    test('deleteForEnvelope leaves other envelopes\' files intact', () async {
      final keep = await write('e2', 'video.mp4', const [9]);
      await write('e1', 'video.mp4', const [1]);
      await store.deleteForEnvelope('e1');
      expect(keep.existsSync(), isTrue);
    });

    test('deleteForEnvelope does not match an envelope sharing a prefix',
        () async {
      final keep = await write('e10', 'video.mp4', const [9]);
      await store.deleteForEnvelope('e1');
      expect(keep.existsSync(), isTrue);
    });

    test('deleteForEnvelope leaves unrelated temp files untouched', () async {
      final other = File(p.join(tempDir.path, 'nanb-ring.wav'));
      await other.writeAsBytes(const [0]);
      await write('e1', 'video.mp4', const [1]);
      await store.deleteForEnvelope('e1');
      expect(other.existsSync(), isTrue);
    });

    test('sweepAll removes every temp-media file', () async {
      final a = await write('e1', 'video.mp4', const [1]);
      final b = await write('e2', 'doc.pdf', const [2]);
      await store.sweepAll();
      expect(a.existsSync(), isFalse);
      expect(b.existsSync(), isFalse);
    });

    test('sweepAll leaves non-prefixed temp files untouched', () async {
      final other = File(p.join(tempDir.path, 'nanb-ring.wav'));
      await other.writeAsBytes(const [0]);
      await write('e1', 'video.mp4', const [1]);
      await store.sweepAll();
      expect(other.existsSync(), isTrue);
    });

    test('sweepAll is a no-op on an empty temp dir', () async {
      await store.sweepAll();
      expect(tempDir.listSync(), isEmpty);
    });
  });

  group('TempMediaStoreInMemory', () {
    test('records allocate / deleteForEnvelope / sweepAll calls', () async {
      final store = TempMediaStoreInMemory();
      await store.allocate(envelopeId: 'e1', label: 'x');
      await store.deleteForEnvelope('e1');
      await store.deleteForEnvelope('e2');
      await store.sweepAll();
      expect(store.allocated, hasLength(1));
      expect(store.deletedEnvelopes, ['e1', 'e2']);
      expect(store.sweepAllCount, 1);
    });
  });
}
