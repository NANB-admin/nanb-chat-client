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
import 'package:nanb_chat/features/chat/models/conversation_kind.dart';
import 'package:nanb_chat/features/chat/models/crypto_mode.dart';
import 'package:nanb_chat/features/chat/models/group_member.dart';
import 'package:nanb_chat/features/chat/models/message_kind.dart';
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
  Future<FetchKeyPackageResult> lookupKeyPackage(String username) async =>
      throw UnimplementedError();

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
  Future<int> ackMessages(List<String> envelopeIds) async {
    ackedEnvelopeIds.addAll(envelopeIds);
    return envelopeIds.length;
  }

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

  /// When non-null, [decryptAndInspect] returns this result instead of the default.
  DecryptMlsResult? nextDecryptResult;

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

  final List<String> removeMemberCalls = [];

  @override
  Future<List<int>> removeMember({
    required String groupId,
    required String targetDeviceId,
  }) async {
    removeMemberCalls.add(targetDeviceId);
    return List<int>.filled(8, 0xCD);
  }

  @override
  Future<int> currentEpoch(String groupId) async => currentEpochResult;

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
  }) async {
    final next = nextDecryptResult;
    if (next != null) {
      nextDecryptResult = null;
      return next;
    }
    return DecryptMlsResult(
      plaintext: List<int>.from(ciphertext),
      selfRemoved: false,
      newEpoch: null,
    );
  }

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
  deviceId: 'self-device-id',
  jwt: 'jwt',
  username: 'self',
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

/// Group conversation with self + @a + @b.
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
        // accountId must match the session's ('self-acc') — self-leave is now
        // detected by account, not device.
        const GroupMember(
          accountId: 'self-acc',
          username: '@self',
          deviceId: 'self-device-id',
          identityPubKey: [1, 2, 3],
          x25519PubKey: [4, 5, 6],
          isAdmin: true,
          isSelf: true,
        ),
        _gm('@a', 'dev-a'),
        _gm('@b', 'dev-b'),
      ],
      mlsEpoch: 1,
      cryptoMode: CryptoMode.mls,
    );

/// 1:1 conversation for error-case tests.
Conversation _oneToOneConvo() => const Conversation(
      id: '1to1:a:b',
      peerUsername: '@peer',
      peerAccountId: 'acc-peer',
      peerDeviceId: 'dev-peer',
      peerIdentityPubKey: [],
      peerX25519PubKey: [],
      messages: [],
      unreadCount: 0,
    );

Envelope _envelope({
  required String conversationId,
  required String type,
  required String senderDeviceId,
  required List<int> ciphertext,
}) =>
    Envelope(
      envelopeId: 'env-test',
      version: 'v1',
      domain: 'nanb.link',
      envelopeType: type,
      conversationId: conversationId,
      senderDeviceId: senderDeviceId,
      recipientAccountId: 'self-acc',
      recipientDeviceId: 'self-device-id',
      ciphertext: ciphertext,
      serverTs: DateTime.utc(2026, 5, 16, 12),
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

    notifier.seed(_groupConvo());
    notifier.seed(_oneToOneConvo());
  });

  tearDown(() async {
    notifier.dispose();
    supervisor.dispose();
    await ws.dispose();
  });

  test('removeMemberFromGroup throws if conversation is not a group', () async {
    await expectLater(
      () => notifier.removeMemberFromGroup(
        conversationId: '1to1:a:b',
        targetDeviceId: 'dev-x',
      ),
      throwsA(isA<StateError>()),
    );
  });

  test('removeMemberFromGroup throws if target not in group', () async {
    await expectLater(
      () => notifier.removeMemberFromGroup(
        conversationId: 'group:g1',
        targetDeviceId: 'dev-not-here',
      ),
      throwsA(isA<StateError>()),
    );
  });

  test(
    'removeMemberFromGroup admin path sends Commit to all + member_removed system event to remaining',
    () async {
      await notifier.removeMemberFromGroup(
        conversationId: 'group:g1',
        targetDeviceId: 'dev-a',
      );

      // Commit envelopes: 3 (self + @a + @b — including the removed device)
      final commits = fakeApi.submittedMessages
          .where((p) => p.envelopeType == EnvelopeType.mlsHandshake)
          .toList();
      expect(commits.length, 3);

      // System events (member_removed application message): 2 (sent to remaining — self + @b)
      final sysEvs = fakeApi.submittedMessages
          .where((p) => p.envelopeType == EnvelopeType.mlsApplication)
          .toList();
      expect(sysEvs.length, 2);

      // Local state: @a is gone
      final convo = notifier.byId('group:g1')!;
      expect(convo.members.length, 2);
      expect(convo.members.any((m) => m.deviceId == 'dev-a'), false);
    },
  );

  test('removeMemberFromGroup evicts ALL of a member account\'s devices',
      () async {
    // @a has TWO device leaves in the group.
    notifier.seed(Conversation(
      id: 'group:g2',
      peerUsername: '',
      peerAccountId: '',
      peerDeviceId: '',
      peerIdentityPubKey: const [],
      peerX25519PubKey: const [],
      messages: const [],
      unreadCount: 0,
      kind: ConversationKind.group,
      groupName: 'G2',
      members: [
        const GroupMember(
          accountId: 'self-acc',
          username: '@self',
          deviceId: 'self-device-id',
          identityPubKey: [],
          x25519PubKey: [],
          isAdmin: true,
          isSelf: true,
        ),
        _gm('@a', 'dev-a'),
        _gm('@a', 'dev-a2'), // second device of the SAME account
        _gm('@b', 'dev-b'),
      ],
      mlsEpoch: 1,
      cryptoMode: CryptoMode.mls,
    ));

    await notifier.removeMemberFromGroup(
        conversationId: 'group:g2', targetDeviceId: 'dev-a');

    // Both of @a's device leaves were removed (one Commit each).
    expect(fakeBridge.removeMemberCalls, containsAll(['dev-a', 'dev-a2']));
    final convo = notifier.byId('group:g2')!;
    expect(convo.members.any((m) => m.accountId == 'acc-@a'), isFalse,
        reason: 'the whole account is gone, not just one device');
    expect(convo.members.length, 2); // self + @b
  });

  test('removeRevokedDeviceFromGroups evicts our revoked device from a group',
      () async {
    // A group where one of OUR account\'s other devices is a member.
    notifier.seed(Conversation(
      id: 'group:g3',
      peerUsername: '',
      peerAccountId: '',
      peerDeviceId: '',
      peerIdentityPubKey: const [],
      peerX25519PubKey: const [],
      messages: const [],
      unreadCount: 0,
      kind: ConversationKind.group,
      groupName: 'G3',
      members: [
        const GroupMember(
          accountId: 'self-acc',
          username: '@self',
          deviceId: 'self-device-id',
          identityPubKey: [],
          x25519PubKey: [],
          isAdmin: true,
          isSelf: true,
        ),
        const GroupMember(
          accountId: 'self-acc',
          username: '@self',
          deviceId: 'self-dev-2', // our sibling device, about to be revoked
          identityPubKey: [],
          x25519PubKey: [],
          isAdmin: false,
          isSelf: true,
        ),
        _gm('@b', 'dev-b'),
      ],
      mlsEpoch: 1,
      cryptoMode: CryptoMode.mls,
    ));

    await notifier.removeRevokedDeviceFromGroups('self-dev-2');

    expect(fakeBridge.removeMemberCalls, contains('self-dev-2'));
    final convo = notifier.byId('group:g3')!;
    expect(convo.members.any((m) => m.deviceId == 'self-dev-2'), isFalse);
  });

  test('removeMemberFromGroup self-leave deletes the conversation locally', () async {
    await notifier.removeMemberFromGroup(
      conversationId: 'group:g1',
      targetDeviceId: 'self-device-id', // matches the fake session's deviceId
    );

    expect(notifier.byId('group:g1'), isNull);
  });

  test(
    'inbound MLS handshake commit removing self injects you_were_removed system message + clears members',
    () async {
      fakeBridge.nextDecryptResult = DecryptMlsResult(
        plaintext: null,
        selfRemoved: true,
        newEpoch: null,
      );

      await notifier.handleEnvelopeForTest(_envelope(
        conversationId: 'group:g1',
        type: EnvelopeType.mlsHandshake,
        senderDeviceId: 'dev-a', // @a is the "by" attribution
        ciphertext: const [9, 9, 9],
      ));

      final convo = notifier.byId('group:g1')!;

      // Members cleared (composer will be disabled by Task 17)
      expect(convo.members, isEmpty);

      // System message appended
      expect(convo.messages.last.kind, MessageKind.system);
      final ev = SystemEvent.tryDecode(convo.messages.last.body)!;
      expect(ev.kind, SystemEventKind.youWereRemoved);
    },
  );

  test(
    'inbound MLS application message persists updated epoch when changed',
    () async {
      fakeBridge.nextDecryptResult = DecryptMlsResult(
        plaintext: utf8.encode('hi'),
        selfRemoved: false,
        newEpoch: 10,
      );

      await notifier.handleEnvelopeForTest(_envelope(
        conversationId: 'group:g1',
        type: EnvelopeType.mlsApplication,
        senderDeviceId: 'dev-a',
        ciphertext: const [0],
      ));

      final convo = notifier.byId('group:g1')!;
      expect(convo.mlsEpoch, 10);
    },
  );

  test(
    '_onMlsHandshake acks the envelope after processing a normal commit',
    () async {
      fakeBridge.nextDecryptResult = DecryptMlsResult(
        plaintext: null,
        selfRemoved: false,
        newEpoch: 10,
      );

      await notifier.handleEnvelopeForTest(_envelope(
        conversationId: 'group:g1',
        type: EnvelopeType.mlsHandshake,
        senderDeviceId: 'dev-a',
        ciphertext: const [0],
      ));

      expect(fakeApi.ackedEnvelopeIds, contains('env-test'));
    },
  );

  test(
    '_onMlsApplication acks the envelope when plaintext is null',
    () async {
      fakeBridge.nextDecryptResult = DecryptMlsResult(
        plaintext: null,
        selfRemoved: false,
        newEpoch: 5,
      );

      await notifier.handleEnvelopeForTest(_envelope(
        conversationId: 'group:g1',
        type: EnvelopeType.mlsApplication,
        senderDeviceId: 'dev-a',
        ciphertext: const [0],
      ));

      expect(fakeApi.ackedEnvelopeIds, contains('env-test'));
    },
  );

  test(
    'conversations sort orders messageless groups by groupName alphabetically',
    () async {
      // Add three messageless groups named "Zed", "Apple", "Mango"
      notifier.seed(Conversation(
        id: 'group:z1',
        peerUsername: '',
        peerAccountId: '',
        peerDeviceId: '',
        peerIdentityPubKey: const [],
        peerX25519PubKey: const [],
        messages: const [],
        unreadCount: 0,
        kind: ConversationKind.group,
        groupName: 'Zed',
        members: const [],
        mlsEpoch: 1,
        cryptoMode: CryptoMode.mls,
      ));

      notifier.seed(Conversation(
        id: 'group:a1',
        peerUsername: '',
        peerAccountId: '',
        peerDeviceId: '',
        peerIdentityPubKey: const [],
        peerX25519PubKey: const [],
        messages: const [],
        unreadCount: 0,
        kind: ConversationKind.group,
        groupName: 'Apple',
        members: const [],
        mlsEpoch: 1,
        cryptoMode: CryptoMode.mls,
      ));

      notifier.seed(Conversation(
        id: 'group:m1',
        peerUsername: '',
        peerAccountId: '',
        peerDeviceId: '',
        peerIdentityPubKey: const [],
        peerX25519PubKey: const [],
        messages: const [],
        unreadCount: 0,
        kind: ConversationKind.group,
        groupName: 'Mango',
        members: const [],
        mlsEpoch: 1,
        cryptoMode: CryptoMode.mls,
      ));

      final sorted = notifier.conversations;
      final groupIds = sorted.where((c) => c.kind == ConversationKind.group).map((c) => c.id).toList();

      // Expecting order: Apple < Mango < Zed (plus the original Test Group and 1:1 convo)
      expect(groupIds[0], 'group:a1'); // Apple
      expect(groupIds[1], 'group:m1'); // Mango
      expect(groupIds[2], 'group:g1'); // Test Group (original)
      expect(groupIds[3], 'group:z1'); // Zed
    },
  );
}
