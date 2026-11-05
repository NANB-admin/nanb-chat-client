import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:nanb_chat/core/network/api_client.dart';
import 'package:nanb_chat/features/chat/media_pipeline.dart';
import 'package:nanb_chat/features/chat/models/message_kind.dart';

class _MockApi extends Mock implements ApiClient {}

void main() {
  late _MockApi api;

  setUp(() {
    api = _MockApi();
    when(() => api.initMediaUpload(
          sha256: any(named: 'sha256'),
          sizeBytes: any(named: 'sizeBytes'),
          mimeType: any(named: 'mimeType'),
          ttlSeconds: any(named: 'ttlSeconds'),
        )).thenAnswer((_) async => MediaUploadInit(
          mediaId: 'media-1',
          uploadUrl: 'https://example.test/upload',
          uploadExpiry: DateTime.utc(2030),
        ));
    when(() => api.putBytesToUrl(
          url: any(named: 'url'),
          bytes: any(named: 'bytes'),
          mimeType: any(named: 'mimeType'),
        )).thenAnswer((_) async {});
  });

  test('upload forwards the retention TTL so S3 expires on the user schedule',
      () async {
    final pipeline = MediaPipeline(
      api,
      ttlProvider: () => const Duration(days: 7),
    );

    await pipeline.upload(
      kind: MessageKind.voice,
      plaintext: [1, 2, 3, 4],
      mimeType: 'audio/mp4',
    );

    verify(() => api.initMediaUpload(
          sha256: any(named: 'sha256'),
          sizeBytes: any(named: 'sizeBytes'),
          mimeType: 'audio/mp4',
          ttlSeconds: 7 * 24 * 3600,
        )).called(1);
  });

  test('upload sends no TTL when no provider is wired (server default)',
      () async {
    final pipeline = MediaPipeline(api);

    await pipeline.upload(
      kind: MessageKind.image,
      plaintext: [1, 2, 3, 4],
      mimeType: 'image/jpeg',
    );

    verify(() => api.initMediaUpload(
          sha256: any(named: 'sha256'),
          sizeBytes: any(named: 'sizeBytes'),
          mimeType: 'image/jpeg',
          ttlSeconds: null,
        )).called(1);
  });
}
