import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:nanb_chat/core/crypto/media_cipher.dart';
import 'package:nanb_chat/core/models/api_error.dart';
import 'package:nanb_chat/core/network/api_client.dart';
import 'package:nanb_chat/features/chat/media_pipeline.dart';
import 'package:nanb_chat/features/chat/models/message_kind.dart';

class _MockApi extends Mock implements ApiClient {}

void main() {
  setUpAll(() {
    registerFallbackValue(<int>[]);
  });

  group('MediaDescriptor', () {
    test('JSON round-trip', () {
      final d = MediaDescriptor(
        kind: MessageKind.image,
        mediaId: 'mid-1',
        key: List<int>.filled(32, 1),
        sha256: List<int>.filled(32, 2),
        sizeBytes: 1234,
        mimeType: 'image/jpeg',
      );
      final r = MediaDescriptor.fromJson(d.toJson());
      expect(r.mediaId, equals(d.mediaId));
      expect(r.key, equals(d.key));
      expect(r.sha256, equals(d.sha256));
      expect(r.sizeBytes, equals(d.sizeBytes));
      expect(r.mimeType, equals(d.mimeType));
    });

    test('looksLikeDescriptor recognizes its own JSON + rejects plain text', () {
      final d = MediaDescriptor(
        kind: MessageKind.image,
        mediaId: 'm',
        key: const [1],
        sha256: const [2],
        sizeBytes: 1,
        mimeType: 'image/png',
      );
      expect(MediaDescriptor.looksLikeDescriptor(d.toJson()), isTrue);
      expect(MediaDescriptor.looksLikeDescriptor('hello there'), isFalse);
      expect(MediaDescriptor.looksLikeDescriptor('{"k":"text"}'), isFalse);
    });
  });

  group('MediaPipeline', () {
    late _MockApi api;
    late MediaPipeline pipeline;

    setUp(() {
      api = _MockApi();
      // No-op backoff so retry tests don't actually sleep.
      pipeline = MediaPipeline(api, delay: (_) async {});
    });

    test('upload encrypts, hashes the cipher, calls /media/init, and PUTs', () async {
      when(() => api.initMediaUpload(
            sha256: any(named: 'sha256'),
            sizeBytes: any(named: 'sizeBytes'),
            mimeType: any(named: 'mimeType'),
          )).thenAnswer((_) async => MediaUploadInit(
            mediaId: 'mid-1',
            uploadUrl: 'https://s3/upload',
            uploadExpiry: DateTime.utc(2026, 5, 9),
          ));
      when(() => api.putBytesToUrl(
            url: any(named: 'url'),
            bytes: any(named: 'bytes'),
            mimeType: any(named: 'mimeType'),
          )).thenAnswer((_) async {});

      final plain = utf8.encode('hello image');
      final descriptor = await pipeline.upload(
        kind: MessageKind.image,
        plaintext: plain,
        mimeType: 'image/jpeg',
      );

      expect(descriptor.mediaId, equals('mid-1'));
      expect(descriptor.key, hasLength(32));
      expect(descriptor.sizeBytes, equals(plain.length));
      expect(descriptor.mimeType, equals('image/jpeg'));
      // Plaintext sha matches what we'd compute fresh.
      final expectedPlainSha = await MediaCipher.sha256(plain);
      expect(descriptor.sha256, equals(expectedPlainSha));

      verify(() => api.putBytesToUrl(
            url: 'https://s3/upload',
            bytes: any(named: 'bytes'),
            mimeType: 'image/jpeg',
          )).called(1);
    });

    test('upload forwards the download audience to /media/init', () async {
      when(() => api.initMediaUpload(
            sha256: any(named: 'sha256'),
            sizeBytes: any(named: 'sizeBytes'),
            mimeType: any(named: 'mimeType'),
            authorizedAccountIds: const ['acc-1', 'acc-2'],
          )).thenAnswer((_) async => MediaUploadInit(
            mediaId: 'mid-1',
            uploadUrl: 'https://s3/upload',
            uploadExpiry: DateTime.utc(2026, 5, 9),
          ));
      when(() => api.putBytesToUrl(
            url: any(named: 'url'),
            bytes: any(named: 'bytes'),
            mimeType: any(named: 'mimeType'),
          )).thenAnswer((_) async {});

      await pipeline.upload(
        kind: MessageKind.image,
        plaintext: utf8.encode('x'),
        mimeType: 'image/jpeg',
        authorizedAccountIds: const ['acc-1', 'acc-2'],
      );

      // The conversation audience reached /media/init unchanged (the server
      // enforces per-object download access against it + the uploader).
      verify(() => api.initMediaUpload(
            sha256: any(named: 'sha256'),
            sizeBytes: any(named: 'sizeBytes'),
            mimeType: any(named: 'mimeType'),
            authorizedAccountIds: const ['acc-1', 'acc-2'],
          )).called(1);
    });

    test('upload retries a transient connection failure, then succeeds',
        () async {
      var initCalls = 0;
      when(() => api.initMediaUpload(
            sha256: any(named: 'sha256'),
            sizeBytes: any(named: 'sizeBytes'),
            mimeType: any(named: 'mimeType'),
          )).thenAnswer((_) async {
        initCalls++;
        if (initCalls == 1) {
          // No status code = a transient connection failure (e.g. the Tor
          // bootstrap window's fail-closed sentinel → connectionRefused).
          throw const ApiError(code: 'network', message: 'connectionRefused');
        }
        return MediaUploadInit(
          mediaId: 'mid-1',
          uploadUrl: 'https://s3/upload',
          uploadExpiry: DateTime.utc(2026, 5, 9),
        );
      });
      when(() => api.putBytesToUrl(
            url: any(named: 'url'),
            bytes: any(named: 'bytes'),
            mimeType: any(named: 'mimeType'),
          )).thenAnswer((_) async {});

      final descriptor = await pipeline.upload(
        kind: MessageKind.image,
        plaintext: utf8.encode('hi'),
        mimeType: 'image/jpeg',
      );

      expect(descriptor.mediaId, equals('mid-1'));
      expect(initCalls, equals(2)); // failed once, retried, succeeded
    });

    test('upload does NOT retry a real HTTP error (status code present)',
        () async {
      var initCalls = 0;
      when(() => api.initMediaUpload(
            sha256: any(named: 'sha256'),
            sizeBytes: any(named: 'sizeBytes'),
            mimeType: any(named: 'mimeType'),
          )).thenAnswer((_) async {
        initCalls++;
        throw const ApiError(
            code: 'unauthorized', message: 'nope', statusCode: 401);
      });

      await expectLater(
        pipeline.upload(
          kind: MessageKind.image,
          plaintext: utf8.encode('hi'),
          mimeType: 'image/jpeg',
        ),
        throwsA(isA<ApiError>()),
      );
      expect(initCalls, equals(1)); // 401 is terminal — no retry
    });

    test('download fetches, decrypts, and verifies plaintext sha256', () async {
      // Build a real ciphertext to round-trip through the pipeline.
      final plain = utf8.encode('hello image');
      final encrypted = await MediaCipher.encrypt(plain);
      final plainSha = await MediaCipher.sha256(plain);

      when(() => api.getMedia('mid-1')).thenAnswer((_) async => MediaDownload(
            downloadUrl: 'https://s3/download',
            downloadExpiry: DateTime.utc(2026, 6, 1),
            mimeType: 'image/jpeg',
            sizeBytes: encrypted.ciphertext.length,
          ));
      when(() => api.getBytesFromUrl('https://s3/download'))
          .thenAnswer((_) async => encrypted.ciphertext);

      final descriptor = MediaDescriptor(
        kind: MessageKind.image,
        mediaId: 'mid-1',
        key: encrypted.key,
        sha256: plainSha,
        sizeBytes: plain.length,
        mimeType: 'image/jpeg',
      );
      final out = await pipeline.download(descriptor);
      expect(out, equals(plain));
    });

    test('download throws StateError on sha256 mismatch', () async {
      final plain = utf8.encode('hello');
      final encrypted = await MediaCipher.encrypt(plain);
      final wrongSha = List<int>.filled(32, 0); // not the real hash

      when(() => api.getMedia(any())).thenAnswer((_) async => MediaDownload(
            downloadUrl: 'https://s3/download',
            downloadExpiry: DateTime.utc(2026, 6, 1),
            mimeType: 'image/jpeg',
            sizeBytes: encrypted.ciphertext.length,
          ));
      when(() => api.getBytesFromUrl(any()))
          .thenAnswer((_) async => encrypted.ciphertext);

      final descriptor = MediaDescriptor(
        kind: MessageKind.image,
        mediaId: 'mid-1',
        key: encrypted.key,
        sha256: wrongSha,
        sizeBytes: plain.length,
        mimeType: 'image/jpeg',
      );
      expect(
        () => pipeline.download(descriptor),
        throwsA(isA<StateError>()),
      );
    });
  });
}
