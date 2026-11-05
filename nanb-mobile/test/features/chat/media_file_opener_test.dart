import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/features/chat/file_opener.dart';
import 'package:nanb_chat/features/chat/media_file_opener.dart';
import 'package:nanb_chat/features/chat/services/temp_media_store.dart';

class _FakeOpener implements FileOpener {
  _FakeOpener({this.result});

  FileOpenResult? result;
  String? lastPath;
  int openCalls = 0;

  @override
  Future<FileOpenResult> open(String path) async {
    openCalls++;
    lastPath = path;
    return result ??
        const FileOpenResult(status: FileOpenStatus.ok);
  }
}

void main() {
  group('MediaFileOpener.sanitizeFilename', () {
    test('returns "attachment" for empty input', () {
      expect(MediaFileOpener.sanitizeFilename(''), 'attachment');
    });

    test('returns "attachment" for whitespace-only input', () {
      expect(MediaFileOpener.sanitizeFilename('   '), 'attachment');
    });

    test('returns "attachment" for "." input', () {
      expect(MediaFileOpener.sanitizeFilename('.'), 'attachment');
    });

    test('returns "attachment" for ".." input', () {
      expect(MediaFileOpener.sanitizeFilename('..'), 'attachment');
    });

    test('strips path-traversal sequences from filename', () {
      final sanitized =
          MediaFileOpener.sanitizeFilename('../../etc/passwd');
      expect(sanitized.contains('/'), isFalse);
      expect(sanitized.contains('\\'), isFalse);
    });

    test('strips Windows-reserved metachars', () {
      final sanitized = MediaFileOpener.sanitizeFilename('a:b*c?d"e<f>g|h.txt');
      expect(sanitized, 'a_b_c_d_e_f_g_h.txt');
    });

    test('strips ASCII control characters', () {
      final sanitized = MediaFileOpener.sanitizeFilename('hello\x00world\x1F.bin');
      expect(sanitized, 'hello_world_.bin');
    });

    test('truncates names longer than maxFilenameLength', () {
      final raw = 'a' * 500 + '.pdf';
      final sanitized = MediaFileOpener.sanitizeFilename(raw);
      expect(sanitized.length, MediaFileOpener.maxFilenameLength);
    });

    test('preserves typical filenames untouched', () {
      expect(
        MediaFileOpener.sanitizeFilename('report-2026-05-21.pdf'),
        'report-2026-05-21.pdf',
      );
    });

    test('preserves filenames with spaces and unicode', () {
      expect(
        MediaFileOpener.sanitizeFilename('Meeting Notes — 5月.docx'),
        'Meeting Notes — 5月.docx',
      );
    });
  });

  group('MediaFileOpener.writeAndOpen', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('nanb_test_');
    });

    tearDown(() async {
      if (tempDir.existsSync()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('writes bytes to disk under temp dir with sanitized name',
        () async {
      final opener = MediaFileOpener(
        opener: _FakeOpener(),
        tempMediaStore: TempMediaStoreImpl(tempDirProvider: () async => tempDir),
      );
      await opener.writeAndOpen(
        envelopeId: 'env-1',
        filename: 'photo.jpg',
        bytes: const [1, 2, 3, 4, 5],
      );
      final file = File(
        '${tempDir.path}/${TempMediaStoreImpl.basenameFor('env-1', 'photo.jpg')}',
      );
      expect(file.existsSync(), isTrue);
      expect(await file.readAsBytes(), const [1, 2, 3, 4, 5]);
    });

    test('prefixes filename with envelopeId to avoid collisions', () async {
      final fake = _FakeOpener();
      final opener = MediaFileOpener(
        opener: fake,
        tempMediaStore: TempMediaStoreImpl(tempDirProvider: () async => tempDir),
      );
      await opener.writeAndOpen(
        envelopeId: 'env-42',
        filename: 'doc.pdf',
        bytes: const [0],
      );
      expect(
        fake.lastPath,
        endsWith(TempMediaStoreImpl.basenameFor('env-42', 'doc.pdf')),
      );
    });

    test('passes a path under tempDir to the FileOpener (no traversal)',
        () async {
      final fake = _FakeOpener();
      final opener = MediaFileOpener(
        opener: fake,
        tempMediaStore: TempMediaStoreImpl(tempDirProvider: () async => tempDir),
      );
      await opener.writeAndOpen(
        envelopeId: 'e1',
        filename: '../../escape.txt',
        bytes: const [9],
      );
      expect(fake.lastPath, isNotNull);
      // Sanitizer replaces `/` with `_`, so the dot sequence can't form a
      // traversal segment — the resulting file lives directly under tempDir.
      expect(fake.lastPath, startsWith(tempDir.path));
      expect(fake.lastPath!.contains('/..'), isFalse);
      expect(fake.lastPath!.contains('../'), isFalse);
      expect(fake.lastPath!.contains('escape.txt'), isTrue);
    });

    test('returns the result from the FileOpener seam unchanged', () async {
      final fake = _FakeOpener(
        result: const FileOpenResult(
          status: FileOpenStatus.noAppToOpen,
          message: 'no viewer',
        ),
      );
      final opener = MediaFileOpener(
        opener: fake,
        tempMediaStore: TempMediaStoreImpl(tempDirProvider: () async => tempDir),
      );
      final result = await opener.writeAndOpen(
        envelopeId: 'e1',
        filename: 'x.weirdext',
        bytes: const [0],
      );
      expect(result.status, FileOpenStatus.noAppToOpen);
      expect(result.message, 'no viewer');
      expect(result.success, isFalse);
    });

    test('invokes the opener exactly once per call', () async {
      final fake = _FakeOpener();
      final opener = MediaFileOpener(
        opener: fake,
        tempMediaStore: TempMediaStoreImpl(tempDirProvider: () async => tempDir),
      );
      await opener.writeAndOpen(
        envelopeId: 'e1',
        filename: 'a.txt',
        bytes: const [0],
      );
      expect(fake.openCalls, 1);
    });

    test('falls back to "attachment" when filename is empty', () async {
      final fake = _FakeOpener();
      final opener = MediaFileOpener(
        opener: fake,
        tempMediaStore: TempMediaStoreImpl(tempDirProvider: () async => tempDir),
      );
      await opener.writeAndOpen(
        envelopeId: 'e1',
        filename: '',
        bytes: const [0],
      );
      expect(
        fake.lastPath,
        endsWith(TempMediaStoreImpl.basenameFor('e1', 'attachment')),
      );
    });
  });

  group('FileOpenResult', () {
    test('success is true only for FileOpenStatus.ok', () {
      expect(
        const FileOpenResult(status: FileOpenStatus.ok).success,
        isTrue,
      );
      for (final s in [
        FileOpenStatus.noAppToOpen,
        FileOpenStatus.fileNotFound,
        FileOpenStatus.permissionDenied,
        FileOpenStatus.error,
      ]) {
        expect(
          FileOpenResult(status: s).success,
          isFalse,
          reason: 'status $s should not be treated as success',
        );
      }
    });
  });
}
