import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:nanb_chat/core/crypto/crypto_bridge.dart';
import 'package:nanb_chat/core/db/app_database.dart';
import 'package:nanb_chat/core/network/api_client.dart';
import 'package:nanb_chat/core/network/ws_client.dart';
import 'package:nanb_chat/core/network/ws_reconnect_supervisor.dart';
import 'package:nanb_chat/core/push/notification_permission_gate.dart';
import 'package:nanb_chat/core/push/push_token_provider.dart';
import 'package:nanb_chat/core/push/push_token_registrar.dart';
import 'package:nanb_chat/core/secure_storage/secure_storage.dart';
import 'package:nanb_chat/features/chat/conversations_notifier.dart';
import 'package:nanb_chat/features/chat/media_pipeline.dart';
import 'package:nanb_chat/features/chat/services/media_cache.dart';
import 'package:nanb_chat/features/chat/pending_upload_staging.dart';
import 'package:nanb_chat/features/chat/services/temp_media_store.dart';
import 'package:nanb_chat/features/chat/models/chat_message.dart';
import 'package:nanb_chat/features/chat/models/message_kind.dart';
import 'package:nanb_chat/features/chat/video/video_thumbnail_generator.dart';
import 'package:nanb_chat/features/chat/video/video_thumbnail_loader.dart';
import 'package:nanb_chat/features/onboarding/session_repository.dart';

class _MockApi extends Mock implements ApiClient {}

class _MockWs extends Mock implements WsClient {}

class _MockSupervisor extends Mock implements WsReconnectSupervisor {}

class _NoopCrypto extends Mock implements CryptoBridge {
  @override
  void clearConversationCrypto(String conversationId) {}
}

/// Serves pre-loaded plaintext bytes from an in-memory map. `upload` is
/// intentionally unimplemented — the thumbnail cache tests only exercise the
/// download path.
class _MapMediaPipeline implements MediaPipeline {
  _MapMediaPipeline(this.bytesByMediaId);

  final Map<String, List<int>> bytesByMediaId;
  int downloadCalls = 0;

  @override
  Future<MediaDescriptor> upload({
    required MessageKind kind,
    required List<int> plaintext,
    required String mimeType,
    String? filename,
    List<int>? waveform,
    int? durationMs,
    List<String>? authorizedAccountIds,
  }) =>
      throw UnimplementedError('upload not used in thumbnail cache tests');

  @override
  Future<List<int>> download(MediaDescriptor descriptor) async {
    downloadCalls++;
    final bytes = bytesByMediaId[descriptor.mediaId];
    if (bytes == null) {
      throw StateError('unknown media id ${descriptor.mediaId}');
    }
    return bytes;
  }
}

/// Returns a fixed [thumbnail] each call and counts invocations. Optional
/// [gate] suspends the call until the test releases it — used to test
/// in-flight deduplication.
class _CountingThumbnailGenerator implements VideoThumbnailGenerator {
  _CountingThumbnailGenerator({this.thumbnail});

  Uint8List? thumbnail;
  int calls = 0;
  Completer<void>? gate;

  @override
  Future<Uint8List?> generate(String videoPath) async {
    calls++;
    if (gate != null) await gate!.future;
    return thumbnail;
  }
}

ChatMessage _videoMessage({
  required String envelopeId,
  required String mediaId,
}) {
  return ChatMessage(
    envelopeId: envelopeId,
    conversationId: 'c1',
    senderDeviceId: 'd1',
    body: '',
    serverTs: DateTime.utc(2026, 1, 1),
    mine: false,
    kind: MessageKind.video,
    mediaId: mediaId,
    mediaKey: const [0],
    mediaSha256: const [0],
    mediaSize: 1,
    mediaMime: 'video/mp4',
  );
}

void main() {
  late Directory tempDir;
  late SecureStorageInMemory storage;
  late _MapMediaPipeline media;
  late _CountingThumbnailGenerator generator;
  late ConversationsNotifier notifier;

  ConversationsNotifier buildNotifier() => ConversationsNotifier(
        apiClient: _MockApi(),
        wsClient: _MockWs(),
        supervisor: _MockSupervisor(),
        crypto: _NoopCrypto(),
        sessions: SessionRepository(storage),
        database: AppDatabaseInMemory(),
        secureStorage: storage,
        media: media,
        pushRegistrar: PushTokenRegistrar(
          api: _MockApi(),
          provider: PushTokenProviderStub(),
        ),
        notificationPermissionGate: NotificationPermissionGate(
          seam: NotificationPermissionSeamStub(),
          storage: storage,
        ),
        videoThumbnailLoader: VideoThumbnailLoader(
          generator: generator,
          tempMediaStore:
              TempMediaStoreImpl(tempDirProvider: () async => tempDir),
        ),
        pendingUploadStaging: PendingUploadStagingInMemory(),
      );

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('nanb_thumb_cache_test_');
    storage = SecureStorageInMemory();
  });

  tearDown(() async {
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('videoThumbnailFor', () {
    test('returns null for non-video messages without invoking generator',
        () async {
      media = _MapMediaPipeline(const {});
      generator = _CountingThumbnailGenerator();
      notifier = buildNotifier();
      final textMsg = ChatMessage(
        envelopeId: 'e1',
        conversationId: 'c1',
        senderDeviceId: 'd1',
        body: 'hello',
        serverTs: DateTime.utc(2026, 1, 1),
        mine: false,
      );
      final result = await notifier.videoThumbnailFor(textMsg);
      expect(result, isNull);
      expect(generator.calls, 0);
      expect(media.downloadCalls, 0);
    });

    test('returns null when descriptor fields are incomplete', () async {
      media = _MapMediaPipeline(const {});
      generator = _CountingThumbnailGenerator();
      notifier = buildNotifier();
      final msg = ChatMessage(
        envelopeId: 'e1',
        conversationId: 'c1',
        senderDeviceId: 'd1',
        body: '',
        serverTs: DateTime.utc(2026, 1, 1),
        mine: false,
        kind: MessageKind.video,
      );
      final result = await notifier.videoThumbnailFor(msg);
      expect(result, isNull);
      expect(generator.calls, 0);
    });

    test('caches the decoded thumbnail so the second call skips decoding',
        () async {
      final thumb = Uint8List.fromList([0xFF, 0x00, 0xFF]);
      media = _MapMediaPipeline({
        'mid-1': const [1, 2, 3],
      });
      generator = _CountingThumbnailGenerator(thumbnail: thumb);
      notifier = buildNotifier();
      final msg = _videoMessage(envelopeId: 'env-1', mediaId: 'mid-1');
      final first = await notifier.videoThumbnailFor(msg);
      final second = await notifier.videoThumbnailFor(msg);
      expect(first, thumb);
      expect(second, thumb);
      expect(generator.calls, 1);
    });

    test('concurrent calls for the same envelope dedupe to a single decode',
        () async {
      final thumb = Uint8List.fromList([0xAA]);
      media = _MapMediaPipeline({
        'mid-1': const [1, 2, 3],
      });
      generator = _CountingThumbnailGenerator(thumbnail: thumb)
        ..gate = Completer<void>();
      notifier = buildNotifier();
      final msg = _videoMessage(envelopeId: 'env-1', mediaId: 'mid-1');
      final f1 = notifier.videoThumbnailFor(msg);
      final f2 = notifier.videoThumbnailFor(msg);
      // Let the gated generator finish.
      generator.gate!.complete();
      final results = await Future.wait([f1, f2]);
      expect(results, [thumb, thumb]);
      expect(generator.calls, 1);
    });

    test('null decode does not poison the cache so a retry re-decodes',
        () async {
      media = _MapMediaPipeline({
        'mid-1': const [1, 2, 3],
      });
      generator = _CountingThumbnailGenerator(thumbnail: null);
      notifier = buildNotifier();
      final msg = _videoMessage(envelopeId: 'env-1', mediaId: 'mid-1');
      final first = await notifier.videoThumbnailFor(msg);
      final second = await notifier.videoThumbnailFor(msg);
      expect(first, isNull);
      expect(second, isNull);
      expect(generator.calls, 2);
    });

    test('LRU eviction drops the oldest entry when over the byte cap',
        () async {
      // Two thumbnails each just over half the cap — caching both forces the
      // first one to be evicted to make room for the second.
      final bigThumb = Uint8List(
        MediaCache.thumbnailMaxBytes ~/ 2 + 1,
      );
      media = _MapMediaPipeline({
        'm1': const [1],
        'm2': const [2],
      });
      generator = _CountingThumbnailGenerator(thumbnail: bigThumb);
      notifier = buildNotifier();
      final msgA = _videoMessage(envelopeId: 'e1', mediaId: 'm1');
      final msgB = _videoMessage(envelopeId: 'e2', mediaId: 'm2');
      await notifier.videoThumbnailFor(msgA);
      await notifier.videoThumbnailFor(msgB);
      // First entry was evicted by the second — re-requesting decodes again.
      await notifier.videoThumbnailFor(msgA);
      expect(generator.calls, 3);
    });

    test('clearLocalData drops cached thumbnails', () async {
      final thumb = Uint8List.fromList([0xCC]);
      media = _MapMediaPipeline({
        'mid-1': const [1],
      });
      generator = _CountingThumbnailGenerator(thumbnail: thumb);
      notifier = buildNotifier();
      final msg = _videoMessage(envelopeId: 'env-1', mediaId: 'mid-1');
      await notifier.videoThumbnailFor(msg);
      expect(generator.calls, 1);
      await notifier.clearLocalData();
      await notifier.videoThumbnailFor(msg);
      // Cache was cleared, so the second call re-runs the generator.
      expect(generator.calls, 2);
    });
  });
}
