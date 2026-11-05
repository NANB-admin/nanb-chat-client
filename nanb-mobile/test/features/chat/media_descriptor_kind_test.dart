import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/features/chat/media_pipeline.dart';
import 'package:nanb_chat/features/chat/models/message_kind.dart';

void main() {
  group('MediaDescriptor kind discriminator', () {
    for (final kind in const [MessageKind.image, MessageKind.voice, MessageKind.video, MessageKind.file]) {
      test('round-trips ${kind.name} via toJson/fromJson', () {
        final original = MediaDescriptor(
          kind: kind,
          mediaId: 'mid-1',
          key: const [1, 2, 3, 4],
          sha256: const [5, 6, 7, 8],
          sizeBytes: 1024,
          mimeType: 'application/octet-stream',
        );
        final parsed = MediaDescriptor.fromJson(original.toJson());
        expect(parsed.kind, kind);
        expect(parsed.mediaId, 'mid-1');
        expect(parsed.key, [1, 2, 3, 4]);
        expect(parsed.sha256, [5, 6, 7, 8]);
        expect(parsed.sizeBytes, 1024);
        expect(parsed.mimeType, 'application/octet-stream');
      });
    }

    test('file kind preserves filename through round-trip', () {
      final d = MediaDescriptor(
        kind: MessageKind.file,
        mediaId: 'mid-2',
        key: const [0],
        sha256: const [0],
        sizeBytes: 1,
        mimeType: 'application/pdf',
        filename: 'spec.pdf',
      );
      final parsed = MediaDescriptor.fromJson(d.toJson());
      expect(parsed.filename, 'spec.pdf');
    });

    test('image kind without filename round-trips with null filename', () {
      final d = MediaDescriptor(
        kind: MessageKind.image,
        mediaId: 'mid-3',
        key: const [0],
        sha256: const [0],
        sizeBytes: 1,
        mimeType: 'image/jpeg',
      );
      final parsed = MediaDescriptor.fromJson(d.toJson());
      expect(parsed.filename, isNull);
    });

    test('looksLikeDescriptor matches all four kinds', () {
      expect(MediaDescriptor.looksLikeDescriptor('{"k":"image","mid":"x"}'), isTrue);
      expect(MediaDescriptor.looksLikeDescriptor('{"k":"voice","mid":"x"}'), isTrue);
      expect(MediaDescriptor.looksLikeDescriptor('{"k":"video","mid":"x"}'), isTrue);
      expect(MediaDescriptor.looksLikeDescriptor('{"k":"file","mid":"x"}'), isTrue);
    });

    test('looksLikeDescriptor rejects plain text + system payloads', () {
      expect(MediaDescriptor.looksLikeDescriptor('hello world'), isFalse);
      expect(MediaDescriptor.looksLikeDescriptor('{"_system":"identity_key_changed"}'), isFalse);
    });

    test('voice kind preserves waveform bytes through round-trip', () {
      final d = MediaDescriptor(
        kind: MessageKind.voice,
        mediaId: 'mid-w',
        key: const [0],
        sha256: const [0],
        sizeBytes: 1,
        mimeType: 'audio/mp4',
        waveform: const [0, 64, 128, 192, 255],
      );
      final parsed = MediaDescriptor.fromJson(d.toJson());
      expect(parsed.waveform, [0, 64, 128, 192, 255]);
    });

    test('voice kind without waveform round-trips with null waveform', () {
      final d = MediaDescriptor(
        kind: MessageKind.voice,
        mediaId: 'mid-w',
        key: const [0],
        sha256: const [0],
        sizeBytes: 1,
        mimeType: 'audio/mp4',
      );
      final parsed = MediaDescriptor.fromJson(d.toJson());
      expect(parsed.waveform, isNull);
    });

    test('legacy peer payload without "w" key parses with null waveform', () {
      const legacy = '{"k":"voice","mid":"m","key":"AA==","sha":"AA==",'
          '"size":1,"mime":"audio/mp4"}';
      final parsed = MediaDescriptor.fromJson(legacy);
      expect(parsed.waveform, isNull);
    });
  });
}
