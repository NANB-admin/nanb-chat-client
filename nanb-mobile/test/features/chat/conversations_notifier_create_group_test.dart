import 'dart:async';

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
import 'package:nanb_chat/core/models/device.dart';
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
import 'package:nanb_chat/features/chat/models/conversation_kind.dart';
import 'package:nanb_chat/features/chat/models/message_kind.dart';
import 'package:nanb_chat/features/chat/models/crypto_mode.dart';
import 'package:nanb_chat/features/chat/models/member_seed.dart';
import 'package:nanb_chat/features/chat/models/group_member_unavailable_exception.dart';
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
  final Map<String, Account> _accounts = {};
  final Map<String, FetchKeyPackageResult> _keyPackages = {};

  /// submitMessage throws for these recipient device ids — simulates a
  /// partial fan-out failure.
  final Set<String> failSubmitForDevices = {};

  /// Per-device key packages keyed by username (multi-device membership).
  final Map<String, List<DeviceKeyPackageResult>> deviceKps = {};

  /// This account's own device fleet (for self-sync group membership).
  List<Device> ownDevices = const [];

  void stubAccount(Account account) => _accounts[account.username] = account;
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
    final a = _accounts[username];
    if (a == null) throw StateError('test: no account stub for $username');
    return a;
  }

  @override
  Future<FetchKeyPackageResult> lookupKeyPackage(String username) async {
    final kp = _keyPackages[username];
    if (kp == null) throw KeyPackageExhaustedException('test: no KP for $username');
    return kp;
  }

  @override
  Future<SubmitMessageResult> submitMessage(SubmitMessagePayload payload) async {
    if (failSubmitForDevices.contains(payload.recipientDeviceId)) {
      throw StateError('test: submit refused for ${payload.recipientDeviceId}');
    }
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
  Future<List<DeviceKeyPackageResult>> lookupDeviceKeyPackages(
          String username) async =>
      deviceKps[username] ?? const [];

  @override
  Future<List<Device>> listDevices() async => ownDevices;

  // unused in this test file
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

  final List<String> createGroupCalls = [];
  final List<({String groupId, List<int> peerKeyPackage})> addMemberCalls = [];
  final List<({String groupId, List<List<int>> peerKeyPackages})>
      addMembersCalls = [];
  int currentEpochResult = 7;

  @override
  Future<String> createGroup({required String conversationId}) async {
    createGroupCalls.add(conversationId);
    return conversationId;
  }

  @override
  Future<AddMemberResult> addMember({
    required String groupId,
    required List<int> peerKeyPackage,
  }) async {
    addMemberCalls.add((groupId: groupId, peerKeyPackage: peerKeyPackage));
    return AddMemberResult(
      welcome: List<int>.filled(32, 0xBB),
      commit: List<int>.filled(32, 0xCC),
    );
  }

  @override
  Future<AddMemberResult> addMembers({
    required String groupId,
    required List<List<int>> peerKeyPackages,
  }) async {
    addMembersCalls.add((groupId: groupId, peerKeyPackages: peerKeyPackages));
    return AddMemberResult(
      welcome: List<int>.filled(32, 0xBB),
      commit: List<int>.filled(32, 0xCC),
    );
  }

  @override
  Future<int> currentEpoch(String groupId) async => currentEpochResult;

  // ── passthrough stubs for the rest of the interface ──────────────────────

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
  }) async => ConversationCryptoState(
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
  }) async => EncryptResult(
        ciphertext: List<int>.from(plaintext),
        newState: state.copyWith(sendCounter: state.sendCounter + 1),
      );

  @override
  Future<DecryptResult> decryptMessage({
    required ConversationCryptoState state,
    required List<int> ciphertext,
  }) async => DecryptResult(
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
  Future<List<int>> encrypt({
    required String groupId,
    required List<int> plaintext,
  }) async => List<int>.from(plaintext);

  @override
  Future<List<int>> decrypt({
    required String groupId,
    required List<int> ciphertext,
  }) async => List<int>.from(ciphertext);

  @override
  Future<String> replaceGroup({
    required String localGroupId,
    required List<int> foreignWelcome,
  }) async => localGroupId;

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
  }) async => throw UnimplementedError();

  @override
  Future<List<int>> download(MediaDescriptor descriptor) async =>
      throw UnimplementedError();
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

MemberSeed _seed(String username, String deviceId) => MemberSeed(
      accountId: 'acc-$username',
      username: username,
      deviceId: deviceId,
      identityPubKey: [1, 2, 3],
      x25519PubKey: [4, 5, 6],
    );

const _selfSession = JwtSession(
  accountId: 'self-acc',
  deviceId: 'self-dev',
  jwt: 'jwt',
  username: 'self',
);

Account _selfAccount() => const Account(
      accountId: 'self-acc',
      username: '@self',
      identityPubKey: [10, 11, 12],
      x25519PubKey: [13, 14, 15],
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

    // Stub self account + session
    fakeApi.stubAccount(_selfAccount());
    await sessions.save(_selfSession);

    // Stub key packages for the two default invitees
    fakeApi.stubKeyPackage('@a', [0xAA, 0xAA]);
    fakeApi.stubKeyPackage('@b', [0xBB, 0xBB]);

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
  });

  tearDown(() async {
    notifier.dispose();
    supervisor.dispose();
    await ws.dispose();
  });

  test(
    'createGroup generates a group:<uuid> id, calls native createGroup + ONE addMembers with all invitees',
    () async {
      final newId = await notifier.createGroup(
        groupName: 'Atlas',
        selfUsername: '@self',
        initialMembers: [_seed('@a', 'dev-a'), _seed('@b', 'dev-b')],
      );

      expect(newId, startsWith('group:'));
      expect(fakeBridge.createGroupCalls, equals([newId]));
      // Single commit adding both invitees — NOT one addMember per invitee
      // (that would strand the first member an epoch behind).
      expect(fakeBridge.addMemberCalls, isEmpty);
      expect(fakeBridge.addMembersCalls.length, equals(1));
      expect(fakeBridge.addMembersCalls.single.peerKeyPackages.length, 2);
    },
  );

  test(
    'createGroup adds every device of invitees + our own other devices',
    () async {
      fakeApi.ownDevices = const [
        Device(deviceId: 'self-dev', accountId: 'self-acc', devicePubKey: []),
        Device(
            deviceId: 'self-dev-2',
            accountId: 'self-acc',
            devicePubKey: [],
            x25519PubKey: [9, 9, 9]),
      ];
      fakeApi.deviceKps['@self'] = const [
        DeviceKeyPackageResult(deviceId: 'self-dev-2', keyPackage: [0x5A]),
      ];
      fakeApi.deviceKps['@a'] = const [
        DeviceKeyPackageResult(deviceId: 'a-d1', keyPackage: [1]),
        DeviceKeyPackageResult(deviceId: 'a-d2', keyPackage: [2]),
      ];
      fakeApi.deviceKps['@b'] = const [
        DeviceKeyPackageResult(deviceId: 'b-d1', keyPackage: [3]),
      ];

      final groupId = await notifier.createGroup(
        groupName: 'Atlas',
        selfUsername: '@self',
        initialMembers: [_seed('@a', 'dev-a'), _seed('@b', 'dev-b')],
      );

      // One commit carrying every device leaf: a-d1, a-d2, b-d1, self-dev-2.
      expect(fakeBridge.addMembersCalls.single.peerKeyPackages.length, 4);
      // A Welcome to each added device.
      final welcomeDevs = fakeApi.submittedMessages
          .where((p) => p.envelopeType == EnvelopeType.mlsWelcome)
          .map((p) => p.recipientDeviceId)
          .toSet();
      expect(welcomeDevs, containsAll(['a-d1', 'a-d2', 'b-d1', 'self-dev-2']));
      // Local roster has one member row per device (incl. self + own other).
      final memberDevs =
          notifier.byId(groupId)!.members.map((m) => m.deviceId).toSet();
      expect(memberDevs,
          containsAll(['self-dev', 'self-dev-2', 'a-d1', 'a-d2', 'b-d1']));
    },
  );

  test(
    'createGroup sends one Welcome envelope per invitee',
    () async {
      await notifier.createGroup(
        groupName: 'Atlas',
        selfUsername: '@self',
        initialMembers: [_seed('@a', 'dev-a'), _seed('@b', 'dev-b')],
      );

      final welcomes = fakeApi.submittedMessages
          .where((p) => p.envelopeType == EnvelopeType.mlsWelcome)
          .toList();
      expect(welcomes.length, equals(2));
      expect(
        welcomes.map((p) => p.recipientDeviceId).toSet(),
        equals({'dev-a', 'dev-b'}),
      );
    },
  );

  test(
    'createGroup tolerates a Welcome submit failure (group still created)',
    () async {
      // @a's Welcome submit fails — must NOT abort the whole group and strand
      // the creator with an unpersisted CoreCrypto group.
      fakeApi.failSubmitForDevices.add('dev-a');

      final groupId = await notifier.createGroup(
        groupName: 'Atlas',
        selfUsername: '@self',
        initialMembers: [_seed('@a', 'dev-a'), _seed('@b', 'dev-b')],
      );

      expect(groupId, startsWith('group:'));
      final convo = notifier.byId(groupId);
      expect(convo, isNotNull, reason: 'group persisted despite the failure');
      expect(convo!.members.length, 3); // self + @a + @b
    },
  );

  test(
    'createGroup persists conversation with kind=group, groupName, members, mlsEpoch',
    () async {
      final newId = await notifier.createGroup(
        groupName: '  Atlas  ',
        selfUsername: '@self',
        initialMembers: [_seed('@a', 'dev-a'), _seed('@b', 'dev-b')],
      );

      final convo = notifier.byId(newId)!;
      expect(convo.kind, equals(ConversationKind.group));
      expect(convo.groupName, equals('Atlas'));
      expect(convo.members.length, equals(3));
      expect(convo.members.any((m) => m.isSelf && m.isAdmin), isTrue);
      expect(convo.cryptoMode, equals(CryptoMode.mls));
      expect(convo.mlsEpoch, equals(fakeBridge.currentEpochResult));
    },
  );

  test(
    'createGroup throws ArgumentError when members count is out of [2,31]',
    () {
      expect(
        () => notifier.createGroup(
          groupName: 'Atlas',
          selfUsername: '@self',
          initialMembers: [_seed('@a', 'dev-a')],
        ),
        throwsArgumentError,
      );
    },
  );

  test(
    'createGroup throws ArgumentError when groupName is blank',
    () {
      expect(
        () => notifier.createGroup(
          groupName: '   ',
          selfUsername: '@self',
          initialMembers: [_seed('@a', 'dev-a'), _seed('@b', 'dev-b')],
        ),
        throwsArgumentError,
      );
    },
  );

  test(
    'createGroup throws GroupMemberUnavailableException (named) when an '
    'invitee has no KeyPackage — not a cryptic crash',
    () async {
      // '@c' has neither device key packages nor a single primary one (pool
      // exhausted / never online) — the fake throws KeyPackageExhausted.
      await expectLater(
        notifier.createGroup(
          groupName: 'Atlas',
          selfUsername: '@self',
          initialMembers: [_seed('@a', 'dev-a'), _seed('@c', 'dev-c')],
        ),
        throwsA(isA<GroupMemberUnavailableException>()
            .having((e) => e.username, 'username', '@c')),
      );
      // Nothing was half-created: no native group, no Welcomes.
      expect(fakeBridge.createGroupCalls, isEmpty);
      expect(fakeApi.submittedMessages, isEmpty);
    },
  );

  test(
    'resolveGroupMemberByUsername builds a MemberSeed from a username lookup '
    '(no 1:1 required)',
    () async {
      fakeApi.stubAccount(const Account(
        accountId: 'newpal-acc',
        username: '@newpal',
        identityPubKey: [1, 2, 3],
        x25519PubKey: [4, 5, 6],
        deviceId: 'newpal-dev',
      ));

      final seed = await notifier.resolveGroupMemberByUsername('@newpal');

      expect(seed.accountId, 'newpal-acc');
      expect(seed.username, '@newpal');
      expect(seed.deviceId, 'newpal-dev');
      expect(seed.identityPubKey, [1, 2, 3]);
      expect(seed.x25519PubKey, [4, 5, 6]);
    },
  );

  test('resolveGroupMemberByUsername rethrows when the username is unknown',
      () {
    expect(
      () => notifier.resolveGroupMemberByUsername('@ghost'),
      throwsA(isA<StateError>()),
    );
  });

  group('group message send fan-out', () {
    Future<String> makeGroup() => notifier.createGroup(
          groupName: 'Atlas',
          selfUsername: '@self',
          initialMembers: [_seed('@a', 'dev-a'), _seed('@b', 'dev-b')],
        );

    test('sendMessage submits one mls_application per OTHER member', () async {
      final groupId = await makeGroup();
      fakeApi.submittedMessages.clear(); // drop createGroup welcomes

      await notifier.sendMessage(
        conversationId: groupId,
        myDeviceId: 'self-dev',
        text: 'hello group',
      );

      final apps = fakeApi.submittedMessages
          .where((p) => p.envelopeType == 'mls_application')
          .toList();
      expect(apps.length, equals(2), reason: 'one envelope per other member');
      expect(apps.map((p) => p.recipientDeviceId).toSet(),
          equals({'dev-a', 'dev-b'}));
      expect(apps.map((p) => p.recipientAccountId).toSet(),
          equals({'acc-@a', 'acc-@b'}));
      // The same group ciphertext fans out to every member.
      expect(apps[0].ciphertext, equals(apps[1].ciphertext));

      final msg = notifier.byId(groupId)!.messages.last;
      expect(msg.failed, isFalse);
      expect(msg.outboxId, anyOf(isNull, isEmpty),
          reason: 'message acked after successful fan-out');
    });

    test('partial fan-out failure still counts as sent', () async {
      final groupId = await makeGroup();
      fakeApi.submittedMessages.clear();
      fakeApi.failSubmitForDevices.add('dev-a');

      await notifier.sendMessage(
        conversationId: groupId,
        myDeviceId: 'self-dev',
        text: 'partial',
      );

      final apps = fakeApi.submittedMessages
          .where((p) => p.envelopeType == 'mls_application')
          .toList();
      expect(apps.length, equals(1));
      expect(apps.single.recipientDeviceId, equals('dev-b'));
      final msg = notifier.byId(groupId)!.messages.last;
      expect(msg.failed, isFalse,
          reason: 'reaching at least one member counts as sent');
    });

    test('total fan-out failure marks the message failed', () async {
      final groupId = await makeGroup();
      fakeApi.submittedMessages.clear();
      fakeApi.failSubmitForDevices.addAll(['dev-a', 'dev-b']);

      // _submitOutbox marks the outbox row failed, then rethrows for the
      // caller's snackbar.
      await expectLater(
        notifier.sendMessage(
          conversationId: groupId,
          myDeviceId: 'self-dev',
          text: 'nobody hears this',
        ),
        throwsA(isA<StateError>()),
      );

      final msg = notifier.byId(groupId)!.messages.last;
      expect(msg.failed, isTrue);
    });
  });
}
