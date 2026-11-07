import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:nanb_chat/core/crypto/add_member_result.dart';
import 'package:nanb_chat/core/crypto/conversation_crypto_state.dart';
import 'package:nanb_chat/core/crypto/crypto_bridge.dart';
import 'package:nanb_chat/core/crypto/decrypt_mls_result.dart';
import 'package:nanb_chat/core/db/app_database.dart';
import 'package:nanb_chat/core/models/account.dart';
import 'package:nanb_chat/core/models/envelope.dart';
import 'package:nanb_chat/core/models/jwt_session.dart';
import 'package:nanb_chat/core/network/api_client.dart';
import 'package:nanb_chat/core/network/connection_state.dart';
import 'package:nanb_chat/core/network/ws_client.dart';
import 'package:nanb_chat/core/network/ws_connection_event.dart';
import 'package:nanb_chat/core/network/ws_reconnect_supervisor.dart';
import 'package:nanb_chat/core/push/notification_permission_gate.dart';
import 'package:nanb_chat/core/push/push_token_provider.dart';
import 'package:nanb_chat/core/push/push_token_registrar.dart';
import 'package:nanb_chat/core/secure_storage/secure_storage.dart';
import 'package:nanb_chat/features/chat/conversations_notifier.dart';
import 'package:nanb_chat/features/chat/media_pipeline.dart';
import 'package:nanb_chat/features/chat/models/chat_message.dart';
import 'package:nanb_chat/features/chat/models/message_kind.dart';
import 'package:nanb_chat/features/chat/pending_upload_staging.dart';
import 'package:nanb_chat/features/chat/services/sticker_marker.dart';
import 'package:nanb_chat/features/chat/video/video_thumbnail_generator.dart';
import 'package:nanb_chat/features/chat/video/video_thumbnail_loader.dart';
import 'package:nanb_chat/features/onboarding/session_repository.dart';

class _MockApi extends Mock implements ApiClient {}

class _NoopVideoThumbnailGenerator implements VideoThumbnailGenerator {
  @override
  Future<Uint8List?> generate(String videoPath) async => null;
}

/// MediaPipeline that lets the test gate each upload until released. Useful
/// for sequencing LIFO ordering when multiple sends queue before any
/// resolves. [upload] also throws when [throwOn] is set so failure paths
/// are exercisable.
class _GatedMediaPipeline implements MediaPipeline {
  /// When true (default), uploads resolve immediately. Otherwise the test
  /// must call [releaseNext] (or [releaseAll]) for each queued upload to let
  /// the worker proceed.
  bool autoComplete = true;
  Object? throwOn;

  int idCounter = 0;
  final List<Completer<void>> _gates = [];
  final List<MessageKind> uploadKinds = [];

  /// Releases the next-queued upload so it resolves.
  void releaseNext() {
    if (_gates.isEmpty) {
      throw StateError('release: no gated upload waiting');
    }
    _gates.removeAt(0).complete();
  }

  /// Releases every queued upload at once.
  void releaseAll() {
    while (_gates.isNotEmpty) {
      _gates.removeAt(0).complete();
    }
  }

  @override
  Future<MediaDescriptor> upload({
    required MessageKind kind,
    required List<int> plaintext,
    required String mimeType,
    String? filename,
    List<int>? waveform,
    int? durationMs,
    List<String>? authorizedAccountIds,
  }) async {
    uploadKinds.add(kind);
    if (!autoComplete) {
      final c = Completer<void>();
      _gates.add(c);
      await c.future;
    }
    if (throwOn != null) throw throwOn!;
    final id = 'media-${++idCounter}';
    return MediaDescriptor(
      kind: kind,
      mediaId: id,
      key: List<int>.filled(32, 0xAB),
      sha256: List<int>.filled(32, 0xCD),
      sizeBytes: plaintext.length,
      mimeType: mimeType,
      filename: filename,
      waveform: waveform,
    );
  }

  @override
  Future<List<int>> download(MediaDescriptor descriptor) async =>
      throw UnimplementedError('download not used in these tests');
}

class _FakeWs implements WsClient {
  @override
  void sendEphemeral(Map<String, dynamic> frame) {}

  @override
  bool sendAckFrame(List<String> envelopeIds) => false;

  @override
  bool get isConnected => false;

  /// Default: no socket, so the notifier falls back to HTTP — preserving the
  /// pre-existing behaviour of every test that doesn't care about the socket
  /// drain path.
  @override
  Future<List<Envelope>> catchupOverSocket(
    String clientRef, {
    int? limit,
    DateTime? since,
    Duration timeout = const Duration(seconds: 10),
  }) async =>
      throw const WsNotConnectedException();

  @override
  Future<({String envelopeId, DateTime serverTs})> sendAndAwaitAck(
    Map<String, dynamic> frame,
    String clientRef, {
    Duration timeout = const Duration(seconds: 10),
  }) async =>
      throw const WsNotConnectedException();
  final _ctrl = StreamController<Envelope>.broadcast();
  bool connected = false;

  @override
  Stream<Envelope> get envelopes => _ctrl.stream;

  @override
  Stream<void> get disconnects => const Stream<void>.empty();

  @override
  Future<bool> probe({Duration timeout = const Duration(seconds: 5)}) async =>
      false;

  @override
  Future<void> connect(String jwt) async {
    connected = true;
  }

  @override
  Future<void> disconnect() async {
    connected = false;
  }

  Future<void> dispose() async => _ctrl.close();
}

class _FakeSupervisor extends ChangeNotifier implements WsReconnectSupervisor {
  _FakeSupervisor({required this.ws, required this.sessions});
  final WsClient ws;
  final SessionRepository sessions;

  final _events = StreamController<WsConnectionEvent>.broadcast();
  ConnectionState _state = ConnectionState.connecting;

  @override
  ConnectionState get state => _state;

  @override
  Stream<WsConnectionEvent> get events => _events.stream;

  @override
  Future<void> start() async {
    final s = await sessions.current();
    if (s == null) return;
    await ws.connect(s.jwt);
    _state = ConnectionState.connected;
    notifyListeners();
    _events.add(const Reconnected());
  }

  @override
  Future<void> stop() async {
    _state = ConnectionState.connecting;
  }

  @override
  void onAppResumed() {}

  @override
  void clearSignedOut() {}

  @override
  void forceReconnect({String source = 'unknown'}) {}

  @override
  Future<void> verifyConnectionOrReconnect() async {}

  @override
  void dispose() {
    _events.close();
    super.dispose();
  }
}

/// Crypto bridge that copies plaintext to ciphertext so we can read the wire
/// body back from the API call (no real encryption involved).
class _PassthroughCrypto implements CryptoBridge {
  @override
  Future<Set<String>> groupMemberDeviceIds(String groupId) async => const {};

  @override
  Future<bool> consumeMlsStoreReset() async => false;

  @override
  Future<EncryptResult> encryptMessage({
    required ConversationCryptoState state,
    required List<int> plaintext,
  }) async {
    return EncryptResult(
      ciphertext: List<int>.from(plaintext),
      newState: state.copyWith(sendCounter: state.sendCounter + 1),
    );
  }

  @override
  Future<DecryptResult> decryptMessage({
    required ConversationCryptoState state,
    required List<int> ciphertext,
  }) async =>
      DecryptResult(
        plaintext: List<int>.from(ciphertext),
        newState: state.copyWith(recvCounter: state.recvCounter + 1),
      );

  @override
  Future<ConversationCryptoState> initConversationCrypto({
    required String conversationId,
    required List<int> peerX25519PubKey,
  }) async =>
      ConversationCryptoState(
        conversationId: conversationId,
        sendCounter: 0,
        sendChainKey: List<int>.filled(32, 0),
        recvCounter: 0,
        recvChainKey: List<int>.filled(32, 0),
      );

  @override
  Future<IdentityHandle> generateIdentity({List<int>? seed}) async =>
      IdentityHandle(id: 'h', publicKey: const [], x25519PublicKey: const []);

  @override
  Future<IdentityHandle?> currentIdentity() async => null;

  @override
  Future<List<int>> signWithIdentity(IdentityHandle h, List<int> p) async =>
      const [];

  @override
  Future<List<int>> mintKeyPackage(IdentityHandle h) async => const [];

  @override
  void clearConversationCrypto(String conversationId) {}

  @override
  Future<void> wipe() async {}

  @override
  Future<List<int>?> rawIdentitySeed() async => null;

  @override
  Future<void> mlsInit() async {}

  @override
  Future<void> mlsEnsureClient(String deviceId) async {}

  @override
  Future<void> mlsInitReadOnly() async {}

  @override
  Future<void> mlsWipe() async {}

  @override
  Future<List<List<int>>> mintKeyPackages({int count = 100}) async =>
      List.generate(count, (_) => const <int>[]);

  @override
  Future<String> createGroup({required String conversationId}) async =>
      conversationId;

  @override
  Future<AddMemberResult> addMembers({
    required String groupId,
    required List<List<int>> peerKeyPackages,
  }) async =>
      AddMemberResult(welcome: const [], commit: const []);

  @override
  Future<AddMemberResult> addMember({
    required String groupId,
    required List<int> peerKeyPackage,
  }) async =>
      AddMemberResult(welcome: const [], commit: const []);

  @override
  Future<String> processWelcome(List<int> welcomeBytes) async => 'g';

  @override
  Future<void> processCommit({
    required String groupId,
    required List<int> commitBytes,
  }) async {}

  @override
  Future<int> currentEpoch(String groupId) async => 0;

  @override
  Future<List<int>> encrypt({
    required String groupId,
    required List<int> plaintext,
  }) async =>
      List<int>.from(plaintext);

  @override
  Future<List<int>> decrypt({
    required String groupId,
    required List<int> ciphertext,
  }) async =>
      List<int>.from(ciphertext);

  @override
  Future<DecryptMlsResult> decryptAndInspect({
    required String groupId,
    required List<int> ciphertext,
  }) async =>
      DecryptMlsResult(
        plaintext: List<int>.from(ciphertext),
        selfRemoved: false,
        newEpoch: 0,
      );

  @override
  Future<List<int>> removeMember({
    required String groupId,
    required String targetDeviceId,
  }) async =>
      const [];

  @override
  Future<String> replaceGroup({
    required String localGroupId,
    required List<int> foreignWelcome,
  }) async =>
      localGroupId;

  @override
  Future<void> wipeGroup(String groupId) async {}
}

void main() {
  setUpAll(() {
    registerFallbackValue(SubmitMessagePayload(
      conversationId: 'x',
      envelopeType: EnvelopeType.mlsApplication,
      recipientAccountId: 'x',
      recipientDeviceId: 'x',
      ciphertext: const [],
    ));
  });

  const myDevice = 'd-me';
  const peer = 'alice';
  const session = JwtSession(
    accountId: 'me-acc',
    deviceId: myDevice,
    jwt: 'jwt',
    username: 'me',
  );
  Account peerAccount() => const Account(
        accountId: 'a-acc',
        username: peer,
        identityPubKey: [9, 8, 7],
        x25519PubKey: [1, 2, 3],
      );

  late _MockApi api;
  late _FakeWs ws;
  late _FakeSupervisor supervisor;
  late _PassthroughCrypto crypto;
  late SecureStorageInMemory storage;
  late SessionRepository sessions;
  late AppDatabaseInMemory db;
  late _GatedMediaPipeline media;
  late ConversationsNotifier notifier;

  ConversationsNotifier buildNotifier() => ConversationsNotifier(
        apiClient: api,
        wsClient: ws,
        supervisor: supervisor,
        crypto: crypto,
        sessions: sessions,
        database: db,
        secureStorage: storage,
        media: media,
        pushRegistrar:
            PushTokenRegistrar(api: api, provider: PushTokenProviderStub()),
        notificationPermissionGate: NotificationPermissionGate(
          seam: NotificationPermissionSeamStub(),
          storage: storage,
        ),
        videoThumbnailLoader: VideoThumbnailLoader(
          generator: _NoopVideoThumbnailGenerator(),
        ),
        pendingUploadStaging: PendingUploadStagingInMemory(),
      );

  setUp(() async {
    api = _MockApi();
    ws = _FakeWs();
    storage = SecureStorageInMemory();
    sessions = SessionRepository(storage);
    db = AppDatabaseInMemory();
    crypto = _PassthroughCrypto();
    supervisor = _FakeSupervisor(ws: ws, sessions: sessions);
    media = _GatedMediaPipeline();
    notifier = buildNotifier();
    await sessions.save(session);
    await notifier.connect();
    when(() => api.lookupAccount(peer)).thenAnswer((_) async => peerAccount());
    when(() => api.submitMessage(any())).thenAnswer((_) async =>
        SubmitMessageResult(
            envelopeId: 'env-${DateTime.now().microsecondsSinceEpoch}',
            serverTs: DateTime.utc(2026, 5, 22)));
  });

  tearDown(() async {
    await ws.dispose();
    supervisor.dispose();
  });

  group('uploading flag lifecycle', () {
    test('optimistic bubble carries uploading=true until worker drains',
        () async {
      media.autoComplete = false;
      final convoId = await notifier.startConversation(
        myDeviceId: myDevice,
        username: peer,
      );
      // Fire and don't wait — the worker is gated.
      // ignore: unawaited_futures
      notifier.sendImage(
        conversationId: convoId,
        myDeviceId: myDevice,
        imageBytes: const [1, 2, 3],
        mimeType: 'image/jpeg',
      );
      // Yield once so the optimistic insert flushes.
      await Future<void>.delayed(Duration.zero);
      var msgs = notifier.byId(convoId)!.messages;
      expect(msgs.length, 1);
      expect(msgs.single.uploading, isTrue);
      expect(msgs.single.failed, isFalse);
      expect(msgs.single.mediaId, isNull,
          reason: 'descriptor not filled until upload completes');

      media.releaseAll();
      await notifier.waitForUploads(convoId);
      msgs = notifier.byId(convoId)!.messages;
      expect(msgs.single.uploading, isFalse);
      expect(msgs.single.mediaId, isNotNull);
    });
  });

  group('failure path', () {
    test('upload throwing flips message to failed=true, uploading=false',
        () async {
      final convoId = await notifier.startConversation(
        myDeviceId: myDevice,
        username: peer,
      );
      media.throwOn = Exception('S3 down');
      await notifier.sendImage(
        conversationId: convoId,
        myDeviceId: myDevice,
        imageBytes: const [9],
        mimeType: 'image/jpeg',
      );
      await notifier.waitForUploads(convoId);
      final m = notifier.byId(convoId)!.messages.single;
      expect(m.failed, isTrue);
      expect(m.uploading, isFalse);
    });
  });

  group('sticker send', () {
    test('puts the sticker filename marker in the wire descriptor', () async {
      final convoId = await notifier.startConversation(
        myDeviceId: myDevice,
        username: peer,
      );
      await notifier.sendImage(
        conversationId: convoId,
        myDeviceId: myDevice,
        imageBytes: const [1, 2, 3],
        mimeType: 'image/png',
        filename: StickerMarker.filenameFor('image/png'),
      );
      await notifier.waitForUploads(convoId);

      final captured = verify(() => api.submitMessage(captureAny())).captured;
      final wireBody = String.fromCharCodes(
        captured.cast<SubmitMessagePayload>().single.ciphertext,
      );
      // Other header lines can precede the descriptor; pick out its line.
      final descriptorJson = wireBody
          .split('\n')
          .firstWhere(MediaDescriptor.looksLikeDescriptor);
      expect(MediaDescriptor.fromJson(descriptorJson).filename, 'sticker.png');
    });

    test('flags the sender\'s own bubble as a sticker', () async {
      final convoId = await notifier.startConversation(
        myDeviceId: myDevice,
        username: peer,
      );
      await notifier.sendImage(
        conversationId: convoId,
        myDeviceId: myDevice,
        imageBytes: const [1, 2, 3],
        mimeType: 'image/webp',
        filename: StickerMarker.filenameFor('image/webp'),
      );
      await notifier.waitForUploads(convoId);

      final m = notifier.byId(convoId)!.messages.single;
      expect(StickerMarker.isSticker(m), isTrue);
    });

    test('an ordinary photo is not flagged as a sticker', () async {
      final convoId = await notifier.startConversation(
        myDeviceId: myDevice,
        username: peer,
      );
      await notifier.sendImage(
        conversationId: convoId,
        myDeviceId: myDevice,
        imageBytes: const [1, 2, 3],
        mimeType: 'image/jpeg',
      );
      await notifier.waitForUploads(convoId);

      final m = notifier.byId(convoId)!.messages.single;
      expect(StickerMarker.isSticker(m), isFalse);
    });
  });

  group('LIFO ordering', () {
    test('three queued sends drain as A then C then B', () async {
      media.autoComplete = false;
      final convoId = await notifier.startConversation(
        myDeviceId: myDevice,
        username: peer,
      );

      // sendA: fires first, runs first.
      // ignore: unawaited_futures
      notifier.sendImage(
        conversationId: convoId,
        myDeviceId: myDevice,
        imageBytes: const [1],
        mimeType: 'image/jpeg',
        caption: 'A',
      );
      await Future<void>.delayed(Duration.zero);

      // sendB: queues behind A.
      // ignore: unawaited_futures
      notifier.sendImage(
        conversationId: convoId,
        myDeviceId: myDevice,
        imageBytes: const [2],
        mimeType: 'image/jpeg',
        caption: 'B',
      );
      // sendC: queues most-recently — top of LIFO stack.
      // ignore: unawaited_futures
      notifier.sendImage(
        conversationId: convoId,
        myDeviceId: myDevice,
        imageBytes: const [3],
        mimeType: 'image/jpeg',
        caption: 'C',
      );
      await Future<void>.delayed(Duration.zero);

      // Release A → worker pops top (C) next → release C → finally B.
      media.releaseNext(); // A
      await Future<void>.delayed(Duration.zero);
      media.releaseNext(); // C
      await Future<void>.delayed(Duration.zero);
      media.releaseNext(); // B
      await notifier.waitForUploads(convoId);

      // Each upload was submitted to the API; order matches A → C → B.
      final captured = verify(() => api.submitMessage(captureAny())).captured;
      final wireBodies = captured
          .cast<SubmitMessagePayload>()
          .map((p) => String.fromCharCodes(p.ciphertext))
          .toList();
      // Captions are post-fixed to the descriptor with a newline; pluck them.
      final captions = wireBodies
          .map((w) => w.contains('\n') ? w.split('\n').last : '')
          .toList();
      expect(captions, ['A', 'C', 'B']);
    });
  });

  group('retryUpload', () {
    test('clears failed flag and re-runs the upload', () async {
      final convoId = await notifier.startConversation(
        myDeviceId: myDevice,
        username: peer,
      );
      media.throwOn = Exception('first attempt fails');
      await notifier.sendImage(
        conversationId: convoId,
        myDeviceId: myDevice,
        imageBytes: const [1, 2, 3],
        mimeType: 'image/jpeg',
      );
      await notifier.waitForUploads(convoId);
      final outboxId =
          notifier.byId(convoId)!.messages.single.outboxId!;
      expect(notifier.byId(convoId)!.messages.single.failed, isTrue);

      media.throwOn = null;
      final ok = await notifier.retryUpload(
        conversationId: convoId,
        outboxId: outboxId,
      );
      expect(ok, isTrue);
      await notifier.waitForUploads(convoId);
      final m = notifier.byId(convoId)!.messages.single;
      expect(m.failed, isFalse);
      expect(m.uploading, isFalse);
      expect(m.mediaId, isNotNull);
    });

    test('returns false when the bytes are no longer cached', () async {
      final convoId = await notifier.startConversation(
        myDeviceId: myDevice,
        username: peer,
      );
      // Seed a failed outbox message without populating _mediaCache by
      // re-using the public state — fail an upload, then clear the cache via
      // clearLocalData? Easier: fail an upload, then evict by sending a
      // big enough cap miss. Simplest: send + fail + clear out by reaching
      // into the public api... actually the cleanest is to seed directly.
      final convo = notifier.byId(convoId)!;
      notifier.seed(convo.copyWith(
        messages: [
          ChatMessage(
            envelopeId: 'outbox-orphan',
            conversationId: convoId,
            senderDeviceId: myDevice,
            body: 'lost',
            kind: MessageKind.image,
            mine: true,
            outboxId: 'outbox-orphan',
            failed: true,
            serverTs: DateTime.utc(2026, 1, 1),
          ),
        ],
      ));

      final ok = await notifier.retryUpload(
        conversationId: convoId,
        outboxId: 'outbox-orphan',
      );
      expect(ok, isFalse);
      expect(notifier.byId(convoId)!.messages.single.failed, isTrue);
    });
  });

  group('boot recovery', () {
    ConversationsNotifier buildFreshNotifier(PendingUploadStaging staging) {
      return ConversationsNotifier(
        apiClient: api,
        wsClient: ws,
        supervisor: _FakeSupervisor(ws: ws, sessions: sessions),
        crypto: crypto,
        sessions: sessions,
        database: db,
        secureStorage: storage,
        media: media,
        pushRegistrar:
            PushTokenRegistrar(api: api, provider: PushTokenProviderStub()),
        notificationPermissionGate: NotificationPermissionGate(
          seam: NotificationPermissionSeamStub(),
          storage: storage,
        ),
        videoThumbnailLoader: VideoThumbnailLoader(
          generator: _NoopVideoThumbnailGenerator(),
        ),
        pendingUploadStaging: staging,
      );
    }

    test('persisted uploading=true with no staging file is flipped to failed',
        () async {
      final convoId = await notifier.startConversation(
        myDeviceId: myDevice,
        username: peer,
      );
      // Persist a uploading row but DON'T stage any bytes — simulates a
      // crash between writeEncrypted and the DB upsert (or worse, a corrupt
      // staging file).
      await db.upsertMessages(convoId, [
        ChatMessage(
          envelopeId: 'outbox-orphan-row',
          conversationId: convoId,
          senderDeviceId: myDevice,
          body: 'stuck',
          serverTs: DateTime.utc(2026, 5, 22),
          mine: true,
          outboxId: 'outbox-orphan-row',
          kind: MessageKind.image,
          uploading: true,
        ),
      ]);
      final fresh = buildFreshNotifier(PendingUploadStagingInMemory());
      await fresh.connect();
      final recovered = fresh
          .byId(convoId)!
          .messages
          .where((m) => m.outboxId == 'outbox-orphan-row')
          .single;
      expect(recovered.uploading, isFalse);
      expect(recovered.failed, isTrue);
    });

    test('persisted uploading=true with a staging file resumes the upload',
        () async {
      final convoId = await notifier.startConversation(
        myDeviceId: myDevice,
        username: peer,
      );
      // Pre-stage bytes for the resumed upload.
      final sharedStaging = PendingUploadStagingInMemory();
      const recoveredBytes = [1, 2, 3, 4, 5];
      final pendingKey = await sharedStaging.writeEncrypted(
        outboxId: 'outbox-resume',
        plaintext: recoveredBytes,
      );
      await db.upsertMessages(convoId, [
        ChatMessage(
          envelopeId: 'outbox-resume',
          conversationId: convoId,
          senderDeviceId: myDevice,
          body: 'caption',
          serverTs: DateTime.utc(2026, 5, 22),
          mine: true,
          outboxId: 'outbox-resume',
          kind: MessageKind.image,
          mediaMime: 'image/jpeg',
          uploading: true,
          pendingUploadKey: pendingKey,
        ),
      ]);

      final fresh = buildFreshNotifier(sharedStaging);
      await fresh.connect();
      // Worker should have re-enqueued and drained. autoComplete=true on the
      // shared _GatedMediaPipeline so it resolves immediately.
      await fresh.waitForUploads(convoId);

      final resumed = fresh.byId(convoId)!.messages.single;
      expect(resumed.uploading, isFalse);
      expect(resumed.failed, isFalse);
      expect(resumed.mediaId, isNotNull,
          reason: 'upload completed → descriptor populated');
      // Staging file should be cleaned up after the ack.
      final remaining = await sharedStaging.listStagedOutboxIds();
      expect(remaining, isEmpty);
    });

    test('orphan staging files are swept when no DB row references them',
        () async {
      final sharedStaging = PendingUploadStagingInMemory();
      await sharedStaging.writeEncrypted(
        outboxId: 'orphan-1',
        plaintext: const [9],
      );
      await sharedStaging.writeEncrypted(
        outboxId: 'orphan-2',
        plaintext: const [9],
      );
      final fresh = buildFreshNotifier(sharedStaging);
      await fresh.connect();
      final remaining = await sharedStaging.listStagedOutboxIds();
      expect(remaining, isEmpty);
    });

    test('retryUpload after restart reads the staging file', () async {
      final convoId = await notifier.startConversation(
        myDeviceId: myDevice,
        username: peer,
      );
      final sharedStaging = PendingUploadStagingInMemory();
      const stagedBytes = [42, 43, 44];
      final pendingKey = await sharedStaging.writeEncrypted(
        outboxId: 'outbox-retry-after-restart',
        plaintext: stagedBytes,
      );
      // Persist a failed row with a pendingUploadKey — simulates a row that
      // was uploading at restart, then flipped to failed by hand (or by an
      // earlier prod recovery decision).
      await db.upsertMessages(convoId, [
        ChatMessage(
          envelopeId: 'outbox-retry-after-restart',
          conversationId: convoId,
          senderDeviceId: myDevice,
          body: '',
          serverTs: DateTime.utc(2026, 5, 22),
          mine: true,
          outboxId: 'outbox-retry-after-restart',
          kind: MessageKind.image,
          mediaMime: 'image/jpeg',
          failed: true,
          pendingUploadKey: pendingKey,
        ),
      ]);

      final fresh = buildFreshNotifier(sharedStaging);
      await fresh.connect();
      // The retry path should be able to read the staging file even though
      // `_mediaCache` (in-memory only) is empty after a fresh start.
      final ok = await fresh.retryUpload(
        conversationId: convoId,
        outboxId: 'outbox-retry-after-restart',
      );
      expect(ok, isTrue);
      await fresh.waitForUploads(convoId);
      final retried = fresh.byId(convoId)!.messages.single;
      expect(retried.failed, isFalse);
      expect(retried.uploading, isFalse);
      expect(retried.mediaId, isNotNull);
    });
  });
}

