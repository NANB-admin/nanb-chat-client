import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/core/crypto/add_member_result.dart';
import 'package:nanb_chat/core/crypto/conversation_crypto_state.dart';
import 'package:nanb_chat/core/crypto/crypto_bridge.dart';
import 'package:nanb_chat/core/crypto/decrypt_mls_result.dart';
import 'package:nanb_chat/core/crypto/mls_exceptions.dart';
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
import 'package:nanb_chat/features/chat/models/conversation.dart';
import 'package:nanb_chat/features/chat/models/conversation_kind.dart';
import 'package:nanb_chat/features/chat/models/crypto_mode.dart';
import 'package:nanb_chat/features/chat/models/group_member.dart';
import 'package:nanb_chat/features/chat/models/message_kind.dart';
import 'package:nanb_chat/features/chat/models/system_event.dart';
import 'package:nanb_chat/features/chat/pending_upload_staging.dart';
import 'package:nanb_chat/features/chat/video/video_thumbnail_generator.dart';
import 'package:nanb_chat/features/chat/video/video_thumbnail_loader.dart';
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
  final List<String> ackedEnvelopeIds = [];

  @override
  void setBearerToken(String? jwt) {}

  @override
  Future<Account> lookupAccount(String username) async => Account(
        accountId: 'acc-$username',
        username: username,
        identityPubKey: [1, 2, 3],
        x25519PubKey: [4, 5, 6],
      );

  @override
  Future<SubmitMessageResult> submitMessage(
      SubmitMessagePayload payload) async {
    submittedMessages.add(payload);
    return SubmitMessageResult(
      envelopeId: 'env-${submittedMessages.length}',
      serverTs: DateTime.now().toUtc(),
    );
  }

  @override
  Future<int> keyPackageCount() async => 50;

  @override
  Future<List<Envelope>> catchupMessages({DateTime? since, int? limit}) async =>
      [];

  @override
  Future<int> ackMessages(List<String> envelopeIds) async {
    ackedEnvelopeIds.addAll(envelopeIds);
    return envelopeIds.length;
  }

  @override
  Future<int> publishKeyPackages(List<List<int>> keyPackages,
          {bool reset = false}) async =>
      0;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
        'ApiClient.${invocation.memberName} not stubbed',
      );
}

class _RecordingCrypto implements CryptoBridge {
  /// Device ids passed to [removeMember], in call order.
  final List<String> removeMemberCalls = [];

  /// Group ids passed to [wipeGroup], in call order.
  final List<String> wipeGroupCalls = [];

  int processWelcomeCalls = 0;

  /// When non-null, [replaceGroup] throws this instead of succeeding.
  Object? replaceGroupError;

  @override
  Future<bool> consumeMlsStoreReset() async => false;

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
  Future<List<int>> removeMember({
    required String groupId,
    required String targetDeviceId,
  }) async {
    removeMemberCalls.add(targetDeviceId);
    return List<int>.filled(8, 0xCD);
  }

  @override
  Future<int> currentEpoch(String groupId) async => 5;

  @override
  Future<List<int>> encrypt({
    required String groupId,
    required List<int> plaintext,
  }) async =>
      List<int>.from(plaintext);

  @override
  Future<DecryptMlsResult> decryptAndInspect({
    required String groupId,
    required List<int> ciphertext,
  }) async =>
      DecryptMlsResult(
        plaintext: List<int>.from(ciphertext),
        selfRemoved: false,
        newEpoch: null,
      );

  @override
  Future<String> processWelcome(List<int> welcomeBytes) async {
    processWelcomeCalls++;
    return 'stub-group';
  }

  @override
  Future<String> replaceGroup({
    required String localGroupId,
    required List<int> foreignWelcome,
  }) async {
    final err = replaceGroupError;
    if (err != null) throw err;
    return localGroupId;
  }

  @override
  Future<void> wipeGroup(String groupId) async {
    wipeGroupCalls.add(groupId);
  }

  // ── passthrough stubs ─────────────────────────────────────────────────────

  @override
  Future<IdentityHandle> generateIdentity({List<int>? seed}) async =>
      IdentityHandle(id: 'h', publicKey: const [], x25519PublicKey: const []);

  @override
  Future<IdentityHandle?> currentIdentity() async => null;

  @override
  Future<List<int>> signWithIdentity(
          IdentityHandle handle, List<int> payload) async =>
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
}

class _FakeWs implements WsClient {
  final _ctrl = StreamController<Envelope>.broadcast();

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
  deviceId: 'self-device-id',
  jwt: 'jwt',
  username: 'self',
);

const _groupId = 'group:g1';

GroupMember _peer(String username, String deviceId) => GroupMember(
      accountId: 'acc-$username',
      username: username,
      deviceId: deviceId,
      identityPubKey: const [1, 2, 3],
      x25519PubKey: const [4, 5, 6],
      isAdmin: false,
      isSelf: false,
    );

const _selfMember = GroupMember(
  accountId: 'self-acc',
  username: '@self',
  deviceId: 'self-device-id',
  identityPubKey: [1, 2, 3],
  x25519PubKey: [4, 5, 6],
  isAdmin: true,
  isSelf: true,
);

/// Group conversation with self + @a + @b, already migrated to MLS.
Conversation _groupConvo() => Conversation(
      id: _groupId,
      peerUsername: '',
      peerAccountId: '',
      peerDeviceId: '',
      peerIdentityPubKey: const [],
      peerX25519PubKey: const [],
      messages: const [],
      unreadCount: 0,
      kind: ConversationKind.group,
      groupName: 'Test Group',
      members: [_selfMember, _peer('@a', 'dev-a'), _peer('@b', 'dev-b')],
      mlsEpoch: 1,
      cryptoMode: CryptoMode.mls,
    );

Envelope _envelope({
  required String envelopeId,
  required String type,
  required List<int> ciphertext,
  String senderDeviceId = 'dev-a',
}) =>
    Envelope(
      envelopeId: envelopeId,
      version: 'v1',
      domain: 'nanb.link',
      envelopeType: type,
      conversationId: _groupId,
      senderDeviceId: senderDeviceId,
      recipientAccountId: 'self-acc',
      recipientDeviceId: 'self-device-id',
      ciphertext: ciphertext,
      serverTs: DateTime.utc(2026, 7, 27, 12),
    );

/// A `group_info` roster broadcast, encoded the way the wire carries it. The
/// fake bridge's decrypt is the identity function, so the JSON doubles as the
/// ciphertext.
List<int> _groupInfoCiphertext(List<GroupMember> roster) => utf8.encode(
      SystemEvent.groupInfo(
        groupName: 'Test Group',
        epoch: 6,
        members: [
          for (final m in roster)
            GroupInfoMember(
              accountId: m.accountId,
              username: m.username,
              deviceId: m.deviceId,
              identityPubKey: m.identityPubKey,
              x25519PubKey: m.x25519PubKey,
              isAdmin: m.isAdmin,
            ),
        ],
      ).toJsonString(),
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
      pushRegistrar:
          PushTokenRegistrar(api: fakeApi, provider: PushTokenProviderStub()),
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
    notifier.seed(_groupConvo());
  });

  tearDown(() async {
    notifier.dispose();
    supervisor.dispose();
    await ws.dispose();
  });

  group('deleting a group leaves it', () {
    test('removes our own device leaf from the MLS group', () async {
      await notifier.deleteConversation(_groupId);

      expect(fakeBridge.removeMemberCalls, ['self-device-id']);
    });

    test('fans the leave Commit to every other member device', () async {
      await notifier.deleteConversation(_groupId);
      // The Commits are minted inline but shipped detached, so the local
      // delete never blocks on the network — let that fan-out drain.
      await pumpEventQueue();

      final commits = fakeApi.submittedMessages
          .where((p) => p.envelopeType == EnvelopeType.mlsHandshake)
          .toList();
      expect(
        commits.map((p) => p.recipientDeviceId).toList(),
        ['dev-a', 'dev-b'],
      );
    });

    test('still deletes locally when the leave Commit cannot be produced',
        () async {
      fakeBridge.replaceGroupError = null;
      final failing = _ThrowingRemoveMemberCrypto();
      final localNotifier = ConversationsNotifier(
        apiClient: fakeApi,
        wsClient: ws,
        supervisor: supervisor,
        crypto: failing,
        sessions: sessions,
        database: db,
        secureStorage: storage,
        media: _FakeMediaPipeline(),
        pushRegistrar:
            PushTokenRegistrar(api: fakeApi, provider: PushTokenProviderStub()),
        notificationPermissionGate: NotificationPermissionGate(
          seam: NotificationPermissionSeamStub(),
          storage: storage,
        ),
        videoThumbnailLoader: VideoThumbnailLoader(
          generator: _NoopVideoThumbnailGenerator(),
        ),
        pendingUploadStaging: PendingUploadStagingInMemory(),
      );
      localNotifier.seed(_groupConvo());

      await localNotifier.deleteConversation(_groupId);

      expect(localNotifier.byId(_groupId), isNull);
      localNotifier.dispose();
    });

    test('does not send a leave Commit when deleting a 1:1', () async {
      notifier.seed(const Conversation(
        id: '1to1:a:b',
        peerUsername: '@peer',
        peerAccountId: 'acc-peer',
        peerDeviceId: 'dev-peer',
        peerIdentityPubKey: [],
        peerX25519PubKey: [],
        messages: [],
        unreadCount: 0,
        cryptoMode: CryptoMode.mls,
      ));

      await notifier.deleteConversation('1to1:a:b');

      expect(fakeBridge.removeMemberCalls, isEmpty);
    });
  });

  group('a deleted group stays deleted', () {
    test('a redelivered group message does not re-create the conversation',
        () async {
      await notifier.deleteConversation(_groupId);

      await notifier.handleEnvelopeForTest(_envelope(
        envelopeId: 'env-residue',
        type: EnvelopeType.mlsApplication,
        ciphertext: utf8.encode('hello'),
      ));

      expect(notifier.byId(_groupId), isNull);
    });

    test('a redelivered group message is acked so it stops coming back',
        () async {
      await notifier.deleteConversation(_groupId);

      await notifier.handleEnvelopeForTest(_envelope(
        envelopeId: 'env-residue',
        type: EnvelopeType.mlsApplication,
        ciphertext: utf8.encode('hello'),
      ));

      expect(fakeApi.ackedEnvelopeIds, contains('env-residue'));
    });

    test('the tombstone survives a reload of the conversation list', () async {
      await notifier.deleteConversation(_groupId);

      expect(await db.loadDeletedGroupIds(), contains(_groupId));
    });

    test('a re-invite Welcome lifts the tombstone and restores the group',
        () async {
      await notifier.deleteConversation(_groupId);

      await notifier.handleEnvelopeForTest(_envelope(
        envelopeId: 'env-reinvite',
        type: EnvelopeType.mlsWelcome,
        ciphertext: List<int>.filled(8, 0xAA),
      ));

      expect(notifier.byId(_groupId), isNotNull);
    });

    test('a re-invite Welcome clears the persisted tombstone', () async {
      await notifier.deleteConversation(_groupId);

      await notifier.handleEnvelopeForTest(_envelope(
        envelopeId: 'env-reinvite',
        type: EnvelopeType.mlsWelcome,
        ciphertext: List<int>.filled(8, 0xAA),
      ));

      expect(await db.loadDeletedGroupIds(), isEmpty);
    });
  });

  group('a peer roster cannot revoke our own membership', () {
    test('a group_info that omits this device keeps our self member row',
        () async {
      await notifier.handleEnvelopeForTest(_envelope(
        envelopeId: 'env-roster',
        type: EnvelopeType.mlsApplication,
        ciphertext:
            _groupInfoCiphertext([_peer('@a', 'dev-a'), _peer('@b', 'dev-b')]),
      ));

      final convo = notifier.byId(_groupId)!;
      expect(convo.members.any((m) => m.isSelf), isTrue);
    });

    test('a group_info that includes this device still replaces the roster',
        () async {
      await notifier.handleEnvelopeForTest(_envelope(
        envelopeId: 'env-roster',
        type: EnvelopeType.mlsApplication,
        ciphertext: _groupInfoCiphertext([_selfMember, _peer('@a', 'dev-a')]),
      ));

      final convo = notifier.byId(_groupId)!;
      expect(convo.members.map((m) => m.deviceId).toList(),
          ['self-device-id', 'dev-a']);
    });
  });

  group('a re-add Welcome for a group we hold no MLS state for', () {
    test('is adopted as a fresh join instead of being retried forever',
        () async {
      fakeBridge.replaceGroupError =
          const MlsUnknownGroupException("Couldn't find conversation");

      await notifier.handleEnvelopeForTest(_envelope(
        envelopeId: 'env-readd',
        type: EnvelopeType.mlsWelcome,
        ciphertext: List<int>.filled(8, 0xAA),
      ));

      expect(fakeBridge.processWelcomeCalls, 1);
    });

    test('is acked so it stops redelivering on every catchup', () async {
      fakeBridge.replaceGroupError =
          const MlsUnknownGroupException("Couldn't find conversation");

      await notifier.handleEnvelopeForTest(_envelope(
        envelopeId: 'env-readd',
        type: EnvelopeType.mlsWelcome,
        ciphertext: List<int>.filled(8, 0xAA),
      ));

      expect(fakeApi.ackedEnvelopeIds, contains('env-readd'));
    });

    test('a genuinely transient failure is left unacked to retry', () async {
      fakeBridge.replaceGroupError = const MlsIoException('disk busy');

      await notifier.handleEnvelopeForTest(_envelope(
        envelopeId: 'env-transient',
        type: EnvelopeType.mlsWelcome,
        ciphertext: List<int>.filled(8, 0xAA),
      ));

      expect(fakeApi.ackedEnvelopeIds, isNot(contains('env-transient')));
    });
  });
}

/// A bridge whose `removeMember` always fails — the offline / dead-group case
/// where a leave Commit can't be produced at all.
class _ThrowingRemoveMemberCrypto extends _RecordingCrypto {
  @override
  Future<List<int>> removeMember({
    required String groupId,
    required String targetDeviceId,
  }) async =>
      throw const MlsUnknownGroupException('no such conversation');
}
