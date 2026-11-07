import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:nanb_chat/core/crypto/add_member_result.dart';
import 'package:nanb_chat/core/crypto/conversation_crypto_state.dart';
import 'package:nanb_chat/core/crypto/crypto_bridge.dart';
import 'package:nanb_chat/core/crypto/decrypt_mls_result.dart';
import 'package:nanb_chat/core/db/app_database.dart';
import 'package:nanb_chat/core/models/envelope.dart';
import 'package:nanb_chat/core/models/jwt_session.dart';
import 'package:nanb_chat/core/network/api_client.dart';
import 'package:nanb_chat/core/network/connection_state.dart';
import 'package:nanb_chat/core/network/ws_client.dart';
import 'package:nanb_chat/core/network/ws_connection_event.dart';
import 'package:nanb_chat/core/network/ws_reconnect_supervisor.dart';
import 'package:nanb_chat/core/secure_storage/secure_storage.dart';
import 'package:nanb_chat/features/chat/conversations_notifier.dart';
import 'package:nanb_chat/features/chat/media_pipeline.dart';
import 'package:nanb_chat/features/chat/pending_upload_staging.dart';
import 'package:nanb_chat/features/chat/video/video_thumbnail_generator.dart';
import 'package:nanb_chat/features/chat/video/video_thumbnail_loader.dart';
import 'package:nanb_chat/features/chat/models/conversation.dart';
import 'package:nanb_chat/features/chat/models/message_kind.dart';
import 'package:nanb_chat/features/chat/models/system_event.dart';
import 'package:nanb_chat/core/push/notification_permission_gate.dart';
import 'package:nanb_chat/core/push/push_token_provider.dart';
import 'package:nanb_chat/core/push/push_token_registrar.dart';
import 'package:nanb_chat/features/onboarding/session_repository.dart';

class _MockApi extends Mock implements ApiClient {}

class _NoopVideoThumbnailGenerator implements VideoThumbnailGenerator {
  @override
  Future<Uint8List?> generate(String videoPath) async => null;
}

class _FakeMediaPipeline implements MediaPipeline {
  final Map<String, _FakeBlob> _store = {};
  int idCounter = 0;
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
    final id = 'media-${++idCounter}';
    final key = List<int>.filled(32, 0xAB);
    final sha = List<int>.filled(32, 0xCD);
    _store[id] = _FakeBlob(plaintext, sha);
    return MediaDescriptor(
      kind: kind,
      mediaId: id,
      key: key,
      sha256: sha,
      sizeBytes: plaintext.length,
      mimeType: mimeType,
      filename: filename,
      waveform: waveform,
    );
  }

  @override
  Future<List<int>> download(MediaDescriptor descriptor) async {
    final blob = _store[descriptor.mediaId];
    if (blob == null) throw StateError('test: unknown media ${descriptor.mediaId}');
    return blob.bytes;
  }
}

class _FakeBlob {
  _FakeBlob(this.bytes, this.sha);
  final List<int> bytes;
  final List<int> sha;
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
  final StreamController<Envelope> _controller = StreamController<Envelope>.broadcast();
  bool connected = false;
  String? connectedJwt;
  int connectCalls = 0;
  int disconnectCalls = 0;

  @override
  Stream<Envelope> get envelopes => _controller.stream;

  @override
  Stream<void> get disconnects => const Stream<void>.empty();

  @override
  Future<bool> probe({Duration timeout = const Duration(seconds: 5)}) async =>
      false;

  @override
  Future<void> connect(String jwt) async {
    connectCalls++;
    connectedJwt = jwt;
    connected = true;
  }

  @override
  Future<void> disconnect() async {
    disconnectCalls++;
    connected = false;
  }

  void push(Envelope env) => _controller.add(env);

  Future<void> dispose() async => _controller.close();
}

class _FakeSupervisor extends ChangeNotifier implements WsReconnectSupervisor {
  _FakeSupervisor({required this.wsClient, required this.sessions});

  final WsClient wsClient;
  final SessionRepository sessions;

  ConnectionState _state = ConnectionState.connecting;
  final _eventsCtrl = StreamController<WsConnectionEvent>.broadcast();
  int startCalls = 0;
  int stopCalls = 0;
  int appResumedCalls = 0;
  bool _disposed = false;

  @override
  ConnectionState get state => _state;

  @override
  Stream<WsConnectionEvent> get events => _eventsCtrl.stream;

  @override
  Future<void> start() async {
    startCalls++;
    final s = await sessions.current();
    if (s == null) return;
    await wsClient.connect(s.jwt);
    _state = ConnectionState.connected;
    notifyListeners();
    _eventsCtrl.add(const Reconnected());
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    _state = ConnectionState.connecting;
    notifyListeners();
  }

  @override
  void onAppResumed() {
    appResumedCalls++;
  }

  @override
  void clearSignedOut() {}

  @override
  void forceReconnect({String source = 'unknown'}) {}

  @override
  Future<void> verifyConnectionOrReconnect() async {}

  void emitReconnected() {
    _state = ConnectionState.connected;
    notifyListeners();
    _eventsCtrl.add(const Reconnected());
  }

  void emitSignedOut() {
    _state = ConnectionState.signedOut;
    notifyListeners();
    _eventsCtrl.add(const SignedOut());
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _eventsCtrl.close();
    super.dispose();
  }
}

class _PassthroughCrypto implements CryptoBridge {
  @override
  Future<Set<String>> groupMemberDeviceIds(String groupId) async => const {};

  @override
  Future<bool> consumeMlsStoreReset() async => false;

  int encryptCalls = 0;
  int decryptCalls = 0;
  int mlsDecryptCalls = 0;
  int processWelcomeCalls = 0;
  int currentEpochCalls = 0;
  String processWelcomeResult = 'stub-group';

  Exception? currentEpochError;

  int currentEpochResult = 0;

  @override
  Future<IdentityHandle> generateIdentity({List<int>? seed}) async =>
      IdentityHandle(id: 'h', publicKey: const [], x25519PublicKey: const []);

  @override
  Future<IdentityHandle?> currentIdentity() async => null;

  @override
  Future<List<int>> signWithIdentity(IdentityHandle handle, List<int> payload) async =>
      List<int>.filled(64, 0);

  @override
  Future<List<int>> mintKeyPackage(IdentityHandle handle) async => const <int>[];

  @override
  Future<ConversationCryptoState> initConversationCrypto({
    required String conversationId,
    required List<int> peerX25519PubKey,
  }) async {
    return ConversationCryptoState(
      conversationId: conversationId,
      sendCounter: 0,
      sendChainKey: List<int>.filled(32, 0),
      recvCounter: 0,
      recvChainKey: List<int>.filled(32, 0),
    );
  }

  @override
  Future<EncryptResult> encryptMessage({
    required ConversationCryptoState state,
    required List<int> plaintext,
  }) async {
    encryptCalls++;
    return EncryptResult(
      ciphertext: List<int>.from(plaintext),
      newState: state.copyWith(sendCounter: state.sendCounter + 1),
    );
  }

  @override
  Future<DecryptResult> decryptMessage({
    required ConversationCryptoState state,
    required List<int> ciphertext,
  }) async {
    decryptCalls++;
    return DecryptResult(
      plaintext: List<int>.from(ciphertext),
      newState: state.copyWith(recvCounter: state.recvCounter + 1),
    );
  }

  final List<String> clearedConversations = [];
  @override
  void clearConversationCrypto(String conversationId) {
    clearedConversations.add(conversationId);
  }

  @override
  Future<void> wipe() async {}

  @override
  Future<List<int>?> rawIdentitySeed() async => List<int>.filled(32, 0);

  @override
  Future<void> mlsInit() async {}

  @override
  Future<void> mlsEnsureClient(String deviceId) async {}

  @override
  Future<void> mlsInitReadOnly() async {}

  @override
  Future<void> mlsWipe() async {}

  int mintKeyPackagesCalls = 0;
  int? mintKeyPackagesLastCount;

  @override
  Future<List<List<int>>> mintKeyPackages({int count = 100}) async {
    mintKeyPackagesCalls++;
    mintKeyPackagesLastCount = count;
    return List.generate(count, (i) => List<int>.filled(64, i & 0xff));
  }

  @override
  Future<String> createGroup({required String conversationId}) async => conversationId;

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
  }) async => AddMemberResult(
        welcome: List<int>.filled(32, 0xAB),
        commit: List<int>.filled(32, 0xCC),
      );

  @override
  Future<String> processWelcome(List<int> welcomeBytes) async {
    processWelcomeCalls++;
    return processWelcomeResult;
  }

  @override
  Future<void> processCommit({
    required String groupId,
    required List<int> commitBytes,
  }) async {}

  @override
  Future<int> currentEpoch(String groupId) async {
    currentEpochCalls++;
    final err = currentEpochError;
    if (err != null) throw err;
    return currentEpochResult;
  }

  @override
  Future<List<int>> encrypt({
    required String groupId,
    required List<int> plaintext,
  }) async => List<int>.from(plaintext);

  @override
  Future<List<int>> decrypt({
    required String groupId,
    required List<int> ciphertext,
  }) async {
    mlsDecryptCalls++;
    return List<int>.from(ciphertext);
  }

  final List<({String localGroupId, List<int> foreignWelcome})> replaceGroupCalls = [];

  @override
  Future<String> replaceGroup({
    required String localGroupId,
    required List<int> foreignWelcome,
  }) async {
    replaceGroupCalls.add((localGroupId: localGroupId, foreignWelcome: foreignWelcome));
    return localGroupId;
  }

  @override
  Future<void> wipeGroup(String groupId) async {}

  @override
  Future<List<int>> removeMember({
    required String groupId,
    required String targetDeviceId,
  }) async => List<int>.filled(32, 0xCD);

  @override
  Future<DecryptMlsResult> decryptAndInspect({
    required String groupId,
    required List<int> ciphertext,
  }) async => DecryptMlsResult(
        plaintext: List<int>.from(ciphertext),
        selfRemoved: false,
        newEpoch: 0,
      );
}

const _myDeviceId = 'me-dev';
const _peerAccountId = 'peer-acc';
const _peerUsername = 'peer';

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

  late _MockApi api;
  late _FakeWs ws;
  late _PassthroughCrypto crypto;
  late SecureStorageInMemory storage;
  late SessionRepository sessions;
  late AppDatabaseInMemory db;
  late _FakeMediaPipeline media;
  late _FakeSupervisor supervisor;
  late ConversationsNotifier notifier;

  const session = JwtSession(
    accountId: 'me-acc',
    deviceId: _myDeviceId,
    jwt: 'jwt-token',
    username: 'me',
  );

  ConversationsNotifier buildNotifier() => ConversationsNotifier(
        apiClient: api,
        wsClient: ws,
        supervisor: supervisor,
        crypto: crypto,
        sessions: sessions,
        database: db,
        secureStorage: storage,
        media: media,
        pushRegistrar: PushTokenRegistrar(api: api, provider: PushTokenProviderStub()),
        notificationPermissionGate: NotificationPermissionGate(
          seam: NotificationPermissionSeamStub(),
          storage: storage,
        ),
        videoThumbnailLoader: VideoThumbnailLoader(
          generator: _NoopVideoThumbnailGenerator(),
        ),
        pendingUploadStaging: PendingUploadStagingInMemory(),
      );

  setUp(() {
    api = _MockApi();
    ws = _FakeWs();
    crypto = _PassthroughCrypto();
    storage = SecureStorageInMemory();
    sessions = SessionRepository(storage);
    db = AppDatabaseInMemory();
    media = _FakeMediaPipeline();
    supervisor = _FakeSupervisor(wsClient: ws, sessions: sessions);
    notifier = buildNotifier();
    when(() => api.catchupMessages(since: any(named: 'since'), limit: any(named: 'limit')))
        .thenAnswer((_) async => <Envelope>[]);
    when(() => api.lookupKeyPackage(any()))
        .thenThrow(const KeyPackageExhaustedException('pool empty'));
    when(() => api.keyPackageCount()).thenAnswer((_) async => 50);
  });

  tearDown(() async {
    notifier.dispose();
    supervisor.dispose();
    await ws.dispose();
  });

  group('notePeerIdentityKeyChange', () {
    test('notePeerIdentityKeyChange injects a system message when the key differs', () async {
      // Create a 1:1 conversation with peerIdentityPubKey = [1,2,3] before connecting
      final convo = Conversation(
        id: 'convo-1',
        peerUsername: _peerUsername,
        peerAccountId: _peerAccountId,
        peerDeviceId: 'peer-dev',
        peerIdentityPubKey: const [1, 2, 3],
        peerX25519PubKey: const [1, 2, 3],
        messages: const [],
        unreadCount: 0,
        verified: false,
      );
      await db.upsertConversation(convo);

      await sessions.save(session);
      await notifier.connect();

      await notifier.notePeerIdentityKeyChange(
        conversationId: 'convo-1',
        newPubKey: const [9, 9, 9],
      );

      final updated = notifier.byId('convo-1')!;
      expect(updated.messages.last.kind, equals(MessageKind.system));

      // body decodes to identity_key_changed
      final ev = SystemEvent.tryDecode(updated.messages.last.body)!;
      expect(ev.kind, equals(SystemEventKind.identityKeyChanged));

      // peer key was rotated
      expect(updated.peerIdentityPubKey, equals([9, 9, 9]));
    });

    test('notePeerIdentityKeyChange is a no-op when key matches', () async {
      final convo = Conversation(
        id: 'convo-1',
        peerUsername: _peerUsername,
        peerAccountId: _peerAccountId,
        peerDeviceId: 'peer-dev',
        peerIdentityPubKey: const [1, 2, 3],
        peerX25519PubKey: const [1, 2, 3],
        messages: const [],
        unreadCount: 0,
        verified: false,
      );
      await db.upsertConversation(convo);

      await sessions.save(session);
      await notifier.connect();

      final before = notifier.byId('convo-1')!.messages.length;
      await notifier.notePeerIdentityKeyChange(
        conversationId: 'convo-1',
        newPubKey: const [1, 2, 3],
      );

      expect(notifier.byId('convo-1')!.messages.length, equals(before));
    });

    test('notePeerIdentityKeyChange does not inject a second event within 5 minutes', () async {
      final convo = Conversation(
        id: 'convo-1',
        peerUsername: _peerUsername,
        peerAccountId: _peerAccountId,
        peerDeviceId: 'peer-dev',
        peerIdentityPubKey: const [1, 2, 3],
        peerX25519PubKey: const [1, 2, 3],
        messages: const [],
        unreadCount: 0,
        verified: false,
      );
      await db.upsertConversation(convo);

      await sessions.save(session);
      await notifier.connect();

      await notifier.notePeerIdentityKeyChange(
        conversationId: 'convo-1',
        newPubKey: const [9, 9, 9],
      );

      // second call with yet-another different key
      await notifier.notePeerIdentityKeyChange(
        conversationId: 'convo-1',
        newPubKey: const [7, 7, 7],
      );

      final systemMsgs = notifier.byId('convo-1')!.messages
          .where((m) => m.kind == MessageKind.system)
          .toList();
      expect(systemMsgs.length, equals(1), reason: 'dedup within 5 minutes');

      // But peer key IS updated to the latest
      expect(notifier.byId('convo-1')!.peerIdentityPubKey, equals([7, 7, 7]));
    });

    test('notePeerIdentityKeyChange no-ops when conversation does not exist', () async {
      await sessions.save(session);
      await notifier.connect();

      // assert: no throw, no state change
      await notifier.notePeerIdentityKeyChange(
        conversationId: 'does-not-exist',
        newPubKey: const [9, 9, 9],
      );

      // Verify no conversation was created
      expect(notifier.byId('does-not-exist'), isNull);
    });
  });
}
