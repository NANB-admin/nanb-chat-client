import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
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
import 'package:nanb_chat/core/secure_storage/secure_storage.dart';
import 'package:nanb_chat/features/chat/conversations_notifier.dart';
import 'package:nanb_chat/features/chat/media_pipeline.dart';
import 'package:nanb_chat/features/chat/pending_upload_staging.dart';
import 'package:nanb_chat/features/chat/video/video_thumbnail_generator.dart';
import 'package:nanb_chat/features/chat/video/video_thumbnail_loader.dart';
import 'package:nanb_chat/features/chat/models/conversation.dart';
import 'package:nanb_chat/features/chat/models/message_kind.dart';
import 'package:nanb_chat/features/chat/models/conversation_kind.dart';
import 'package:nanb_chat/features/chat/models/crypto_mode.dart';
import 'package:nanb_chat/features/chat/models/group_member.dart';
import 'package:nanb_chat/features/chat/models/member_seed.dart';
import 'package:nanb_chat/features/chat/models/system_event.dart';
import 'package:nanb_chat/core/push/notification_permission_gate.dart';
import 'package:nanb_chat/core/push/push_token_provider.dart';
import 'package:nanb_chat/core/push/push_token_registrar.dart';
import 'package:nanb_chat/features/onboarding/session_repository.dart';

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

class _NoopVideoThumbnailGenerator implements VideoThumbnailGenerator {
  @override
  Future<Uint8List?> generate(String videoPath) async => null;
}

class _FakeApiClient implements ApiClient {
  final List<SubmitMessagePayload> submittedMessages = [];
  final Map<String, FetchKeyPackageResult> _keyPackages = {};

  void stubKeyPackage(String username, List<int> kp) {
    _keyPackages[username] = FetchKeyPackageResult(
      keyPackage: kp,
      replenishNeeded: false,
      remainingForUser: 10,
    );
  }

  @override
  void setBearerToken(String? jwt) {}

  @override
  Future<Account> lookupAccount(String username) async {
    // Default — returns a minimal account for any username
    return Account(
      accountId: 'acc-$username',
      username: username,
      identityPubKey: [1, 2, 3],
      x25519PubKey: [4, 5, 6],
    );
  }

  @override
  Future<FetchKeyPackageResult> lookupKeyPackage(String username) async {
    final kp = _keyPackages[username];
    if (kp == null) throw KeyPackageExhaustedException('test: no KP for $username');
    return kp;
  }

  @override
  Future<SubmitMessageResult> submitMessage(SubmitMessagePayload payload) async {
    submittedMessages.add(payload);
    return SubmitMessageResult(
      envelopeId: 'env-${submittedMessages.length}',
      serverTs: DateTime.now().toUtc(),
    );
  }

  @override
  Future<int> keyPackageCount() async => 50;

  @override
  Future<List<Envelope>> catchupMessages({DateTime? since, int? limit}) async => [];

  @override
  Future<int> ackMessages(List<String> envelopeIds) async => 0;

  @override
  Future<int> publishKeyPackages(List<List<int>> keyPackages, {bool reset = false}) async => 0;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
        'ApiClient.${invocation.memberName} not stubbed',
      );
}

class _RecordingCrypto implements CryptoBridge {
  @override
  Future<Set<String>> groupMemberDeviceIds(String groupId) async => const {};

  @override
  Future<bool> consumeMlsStoreReset() async => false;

  int currentEpochResult = 5;

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
      AddMemberResult(
        welcome: List<int>.filled(8, 0xAA),
        commit: List<int>.filled(8, 0xCC),
      );

  @override
  Future<int> currentEpoch(String groupId) async => currentEpochResult;

  @override
  Future<List<int>> encrypt({
    required String groupId,
    required List<int> plaintext,
  }) async =>
      List<int>.from(plaintext);

  // ── passthrough stubs ─────────────────────────────────────────────────────

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
  Future<List<List<int>>> mintKeyPackages({int count = 100}) async =>
      List.generate(count, (i) => List<int>.filled(64, i & 0xff));

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
  Future<EncryptResult> encryptMessage({
    required ConversationCryptoState state,
    required List<int> plaintext,
  }) async =>
      EncryptResult(
        ciphertext: List<int>.from(plaintext),
        newState: state.copyWith(sendCounter: state.sendCounter + 1),
      );

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
  void clearConversationCrypto(String conversationId) {}

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

  @override
  Future<String> processWelcome(List<int> welcomeBytes) async => 'stub-group';

  @override
  Future<void> processCommit({
    required String groupId,
    required List<int> commitBytes,
  }) async {}

  @override
  Future<List<int>> decrypt({
    required String groupId,
    required List<int> ciphertext,
  }) async =>
      List<int>.from(ciphertext);

  @override
  Future<String> replaceGroup({
    required String localGroupId,
    required List<int> foreignWelcome,
  }) async =>
      localGroupId;

  @override
  Future<void> wipeGroup(String groupId) async {}

  @override
  Future<List<int>> removeMember({
    required String groupId,
    required String targetDeviceId,
  }) async =>
      List<int>.filled(32, 0xCD);

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
  @override
  Stream<Envelope> get envelopes => _ctrl.stream;

  @override
  Stream<void> get disconnects => const Stream<void>.empty();
  @override
  Future<bool> probe({Duration timeout = const Duration(seconds: 5)}) async =>
      false;
  @override
  Future<void> connect(String jwt) async {}
  @override
  Future<void> disconnect() async {}
  Future<void> dispose() async => _ctrl.close();
}

class _FakeSupervisor extends ChangeNotifier implements WsReconnectSupervisor {
  final WsClient wsClient;
  final SessionRepository sessions;
  ConnectionState _state = ConnectionState.connecting;
  final _eventsCtrl = StreamController<WsConnectionEvent>.broadcast();
  bool _disposed = false;

  _FakeSupervisor({required this.wsClient, required this.sessions});

  @override
  ConnectionState get state => _state;

  @override
  Stream<WsConnectionEvent> get events => _eventsCtrl.stream;

  @override
  Future<void> start() async {
    final s = await sessions.current();
    if (s == null) return;
    await wsClient.connect(s.jwt);
    _state = ConnectionState.connected;
    notifyListeners();
    _eventsCtrl.add(const Reconnected());
  }

  @override
  Future<void> stop() async {
    _state = ConnectionState.connecting;
    notifyListeners();
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
    if (_disposed) return;
    _disposed = true;
    _eventsCtrl.close();
    super.dispose();
  }
}

class _FakeMediaPipeline implements MediaPipeline {
  @override
  Future<MediaDescriptor> upload({
    required MessageKind kind,
    required List<int> plaintext,
    required String mimeType,
    String? filename,
    List<int>? waveform,
    int? durationMs,
    List<String>? authorizedAccountIds,
  }) async =>
      throw UnimplementedError();

  @override
  Future<List<int>> download(MediaDescriptor descriptor) async =>
      throw UnimplementedError();
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

const _selfSession = JwtSession(
  accountId: 'self-acc',
  deviceId: 'self-dev',
  jwt: 'jwt',
  username: 'self',
);

MemberSeed _seed(String username, String deviceId) => MemberSeed(
      accountId: 'acc-$username',
      username: username,
      deviceId: deviceId,
      identityPubKey: [1, 2, 3],
      x25519PubKey: [4, 5, 6],
    );

GroupMember _gm(String username, String deviceId, {bool isSelf = false}) =>
    GroupMember(
      accountId: 'acc-$username',
      username: username,
      deviceId: deviceId,
      identityPubKey: [1, 2, 3],
      x25519PubKey: [4, 5, 6],
      isAdmin: isSelf,
      isSelf: isSelf,
    );

/// Seed a group conversation with [self, @a, @b] as members.
Conversation _groupConvo() => Conversation(
      id: 'group:g1',
      peerUsername: '',
      peerAccountId: '',
      peerDeviceId: '',
      peerIdentityPubKey: const [],
      peerX25519PubKey: const [],
      messages: const [],
      unreadCount: 0,
      kind: ConversationKind.group,
      groupName: 'Test Group',
      members: [
        _gm('@self', 'self-dev', isSelf: true),
        _gm('@a', 'dev-a'),
        _gm('@b', 'dev-b'),
      ],
      mlsEpoch: 1,
      cryptoMode: CryptoMode.mls,
    );

/// Seed a 1:1 conversation.
Conversation _oneToOneConvo() => const Conversation(
      id: 'convo-1to1',
      peerUsername: '@peer',
      peerAccountId: 'acc-peer',
      peerDeviceId: 'dev-peer',
      peerIdentityPubKey: [],
      peerX25519PubKey: [],
      messages: [],
      unreadCount: 0,
    );

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  late _FakeApiClient fakeApi;
  late _RecordingCrypto fakeBridge;
  late SecureStorageInMemory storage;
  late SessionRepository sessions;
  late AppDatabaseInMemory db;
  late _FakeWs ws;
  late _FakeSupervisor supervisor;
  late ConversationsNotifier notifier;

  setUp(() async {
    fakeApi = _FakeApiClient();
    fakeBridge = _RecordingCrypto();
    storage = SecureStorageInMemory();
    sessions = SessionRepository(storage);
    db = AppDatabaseInMemory();
    ws = _FakeWs();
    supervisor = _FakeSupervisor(wsClient: ws, sessions: sessions);

    await sessions.save(_selfSession);

    notifier = ConversationsNotifier(
      apiClient: fakeApi,
      wsClient: ws,
      supervisor: supervisor,
      crypto: fakeBridge,
      sessions: sessions,
      database: db,
      secureStorage: storage,
      media: _FakeMediaPipeline(),
      pushRegistrar: PushTokenRegistrar(api: fakeApi, provider: PushTokenProviderStub()),
      notificationPermissionGate: NotificationPermissionGate(
        seam: NotificationPermissionSeamStub(),
        storage: storage,
      ),
      videoThumbnailLoader: VideoThumbnailLoader(
        generator: _NoopVideoThumbnailGenerator(),
      ),
      pendingUploadStaging: PendingUploadStagingInMemory(),
    );

    await notifier.connect();

    // Seed group conversation with 3 members (self + @a + @b)
    notifier.seed(_groupConvo());
    // Seed 1:1 conversation for error-case tests
    notifier.seed(_oneToOneConvo());

    // Stub KeyPackage for the new member
    fakeApi.stubKeyPackage('@new', [0xDD, 0xEE]);
  });

  tearDown(() async {
    notifier.dispose();
    supervisor.dispose();
    await ws.dispose();
  });

  test('addMemberToGroup throws if conversation does not exist', () async {
    await expectLater(
      () => notifier.addMemberToGroup(
        conversationId: 'group:does-not-exist',
        newMember: _seed('@new', 'dev-new'),
      ),
      throwsA(isA<StateError>()),
    );
  });

  test('addMemberToGroup throws if conversation is 1:1 (not a group)', () async {
    await expectLater(
      () => notifier.addMemberToGroup(
        conversationId: 'convo-1to1',
        newMember: _seed('@new', 'dev-new'),
      ),
      throwsA(isA<StateError>()),
    );
  });

  test('addMemberToGroup throws if member already in group', () async {
    await expectLater(
      () => notifier.addMemberToGroup(
        conversationId: 'group:g1',
        newMember: _seed('@a', 'dev-a'), // already present
      ),
      throwsA(isA<StateError>()),
    );
  });

  test(
    'addMemberToGroup sends Welcome to new + Commit to each existing + system event to all',
    () async {
      await notifier.addMemberToGroup(
        conversationId: 'group:g1',
        newMember: _seed('@new', 'dev-new'),
      );

      // Welcome: 1 envelope to dev-new with envelopeType mls_welcome
      final welcomes = fakeApi.submittedMessages
          .where((p) => p.envelopeType == EnvelopeType.mlsWelcome)
          .toList();
      expect(welcomes.length, 1);
      expect(welcomes.single.recipientDeviceId, 'dev-new');

      // Commits: 2 envelopes — to the existing members @a + @b. The adder
      // (self) produced the commit and already advanced, so it isn't sent one.
      final commits = fakeApi.submittedMessages
          .where((p) => p.envelopeType == EnvelopeType.mlsHandshake)
          .toList();
      expect(commits.length, 2);

      // Application envelopes split into two broadcasts, distinguished by
      // their decrypted _system kind (passthrough crypto = ciphertext is
      // the plaintext JSON):
      //   - member_joined → all 4 members (incl. self)
      //   - group_info (name + roster) → 3 non-self members
      final appPayloads = fakeApi.submittedMessages
          .where((p) => p.envelopeType == EnvelopeType.mlsApplication)
          .map((p) => SystemEvent.tryDecode(utf8.decode(p.ciphertext)))
          .toList();
      final joined = appPayloads
          .where((e) => e?.kind == SystemEventKind.memberJoined)
          .length;
      final info = appPayloads
          .where((e) => e?.kind == SystemEventKind.groupInfo)
          .length;
      expect(joined, 4, reason: 'member_joined to every member incl. self');
      expect(info, 3, reason: 'group_info roster to the 3 non-self members');
    },
  );

  test('addMemberToGroup persists new member + updated epoch', () async {
    await notifier.addMemberToGroup(
      conversationId: 'group:g1',
      newMember: _seed('@new', 'dev-new'),
    );

    final convo = notifier.byId('group:g1')!;
    expect(convo.members.any((m) => m.username == '@new'), isTrue);
    expect(convo.members.length, 4); // self + @a + @b + @new
    expect(convo.mlsEpoch, fakeBridge.currentEpochResult);
  });
}
