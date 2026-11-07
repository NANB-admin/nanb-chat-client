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
import 'package:nanb_chat/core/models/device.dart';
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
import 'package:nanb_chat/features/chat/models/chat_message.dart';
import 'package:nanb_chat/features/chat/models/conversation.dart';
import 'package:nanb_chat/features/chat/models/message_kind.dart';
import 'package:nanb_chat/features/chat/models/conversation_kind.dart';
import 'package:nanb_chat/features/chat/models/crypto_mode.dart';
import 'package:nanb_chat/features/chat/models/group_member.dart';
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
  List<Device> devices = const [];
  List<DeviceKeyPackageResult> deviceKeyPackages = const [];
  int deviceKpFetches = 0;
  List<AccountDevice> peerDevices = const [];

  @override
  Future<List<Device>> listDevices() async => devices;

  /// When set, the next package lookup fails with it (a dropped connection).
  Object? failNextKpFetch;

  @override
  Future<List<DeviceKeyPackageResult>> lookupDeviceKeyPackages(
      String username) async {
    deviceKpFetches++;
    final fail = failNextKpFetch;
    failNextKpFetch = null;
    if (fail != null) throw fail;
    return deviceKeyPackages;
  }
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
      devices: peerDevices,
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
  /// The group as CoreCrypto sees it. Null means this device holds no group.
  Set<String>? members;

  @override
  Future<Set<String>> groupMemberDeviceIds(String groupId) async {
    final m = members;
    if (m == null) throw StateError('no group $groupId');
    return m;
  }

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
  }) async {
    final m = members;
    if (m != null) members = {...m, utf8.decode(peerKeyPackage)};
    return AddMemberResult(
      welcome: List<int>.filled(8, 0xAA),
      commit: List<int>.filled(8, 0xCC),
    );
  }

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
  void pushDevicesChanged() => _ctrl.add(Envelope(
        envelopeId: '',
        version: 'v1',
        domain: 'nanb.link',
        envelopeType: EnvelopeType.devicesChanged,
        conversationId: '',
        senderDeviceId: '',
        recipientAccountId: 'self-acc',
        recipientDeviceId: 'self-dev',
        ciphertext: const [],
        serverTs: DateTime.utc(2026, 5, 7, 12),
      ));
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

  void emitReconnected() => _eventsCtrl.add(const Reconnected());

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

Device _device(String id, {String? linkedBy}) => Device(
      deviceId: id,
      accountId: 'self-acc',
      devicePubKey: const [],
      x25519PubKey: const [7, 7, 7],
      linkedByDeviceId: linkedBy,
    );

/// The package carries its device id, so the fake group can grow on addMember.
DeviceKeyPackageResult _kp(String deviceId) =>
    DeviceKeyPackageResult(deviceId: deviceId, keyPackage: utf8.encode(deviceId));

GroupMember _member(String accountId, String deviceId,
        {bool isSelf = false}) =>
    GroupMember(
      accountId: accountId,
      username: isSelf ? 'self' : 'peer',
      deviceId: deviceId,
      identityPubKey: const [1],
      x25519PubKey: const [2],
      isAdmin: isSelf,
      isSelf: isSelf,
    );

Conversation _group() => Conversation(
      id: 'group:g1',
      peerUsername: '',
      peerAccountId: '',
      peerDeviceId: '',
      peerIdentityPubKey: const [],
      messages: const [],
      unreadCount: 0,
      kind: ConversationKind.group,
      groupName: 'G',
      members: [
        _member('self-acc', 'self-dev', isSelf: true),
        _member('peer-acc', 'peer-dev'),
      ],
      mlsEpoch: 1,
      cryptoMode: CryptoMode.mls,
    );

Conversation _oneToOne() => Conversation(
      id: Conversation.oneToOneId('self-acc', 'peer-acc'),
      peerUsername: 'peer',
      peerAccountId: 'peer-acc',
      peerDeviceId: 'peer-dev',
      peerIdentityPubKey: const [],
      messages: const [],
      unreadCount: 0,
      cryptoMode: CryptoMode.mls,
    );

void main() {
  late _FakeApiClient api;
  late SecureStorageInMemory storage;
  late SessionRepository sessions;
  late _FakeWs ws;
  late _FakeSupervisor supervisor;
  late ConversationsNotifier notifier;
  late _RecordingCrypto crypto;
  late AppDatabaseInMemory database;

  setUp(() async {
    api = _FakeApiClient();
    crypto = _RecordingCrypto();
    database = AppDatabaseInMemory();
    storage = SecureStorageInMemory();
    sessions = SessionRepository(storage);
    ws = _FakeWs();
    supervisor = _FakeSupervisor(wsClient: ws, sessions: sessions);
    await sessions.save(_selfSession);
    notifier = ConversationsNotifier(
      apiClient: api,
      wsClient: ws,
      supervisor: supervisor,
      crypto: crypto,
      sessions: sessions,
      database: database,
      secureStorage: storage,
      media: _FakeMediaPipeline(),
      pushRegistrar:
          PushTokenRegistrar(api: api, provider: PushTokenProviderStub()),
      notificationPermissionGate: NotificationPermissionGate(
        seam: NotificationPermissionSeamStub(),
        storage: storage,
      ),
      videoThumbnailLoader:
          VideoThumbnailLoader(generator: _NoopVideoThumbnailGenerator()),
      pendingUploadStaging: PendingUploadStagingInMemory(),
    );
  });

  tearDown(() async {
    notifier.dispose();
    supervisor.dispose();
    await ws.dispose();
  });

  Future<void> connectWith({
    required List<Device> devices,
    List<DeviceKeyPackageResult> kps = const [],
    List<Conversation> convos = const [],
    Set<String>? members = const {'self-dev', 'peer-dev'},
  }) async {
    api.devices = devices;
    api.deviceKeyPackages = kps;
    crypto.members = members;
    for (final c in convos) {
      notifier.seed(c);
    }
    await notifier.connect();
    await pumpEventQueue();
  }

  List<SubmitMessagePayload> welcomesTo(String deviceId) => api
      .submittedMessages
      .where((p) =>
          p.envelopeType == EnvelopeType.mlsWelcome &&
          p.recipientDeviceId == deviceId)
      .toList();

  group('who adds a device missing from a group', () {
    test('a member adds it even if it was linked long ago', () async {
      await connectWith(
        devices: [_device('self-dev'), _device('old-sibling')],
        kps: [_kp('old-sibling')],
        convos: [_oneToOne()],
      );
      expect(welcomesTo('old-sibling'), hasLength(1));
    });

    test('a device already in the group is left alone', () async {
      await connectWith(
        devices: [_device('self-dev'), _device('sibling')],
        kps: [_kp('sibling')],
        convos: [_oneToOne()],
        members: {'self-dev', 'sibling', 'peer-dev'},
      );
      expect(welcomesTo('sibling'), isEmpty);
    });

    test('a member that is first in the order adds without waiting', () async {
      await connectWith(
        devices: [
          _device('self-dev'),
          _device('zzz-member'),
          _device('missing'),
        ],
        kps: [_kp('missing')],
        convos: [_oneToOne()],
        members: {'self-dev', 'zzz-member', 'peer-dev'},
      );
      expect(welcomesTo('missing'), hasLength(1));
    });

    test('a member further down the order waits its turn', () async {
      await connectWith(
        devices: [
          _device('aaa-member'),
          _device('self-dev'),
          _device('missing'),
        ],
        kps: [_kp('missing')],
        convos: [_oneToOne()],
        members: {'aaa-member', 'self-dev', 'peer-dev'},
      );
      expect(welcomesTo('missing'), isEmpty);
    });

    test('a member further down the order adds once the first has had its chance',
        () async {
      notifier.ownDeviceRankStep = const Duration(milliseconds: 1);
      await connectWith(
        devices: [
          _device('aaa-member'),
          _device('self-dev'),
          _device('missing'),
        ],
        kps: [_kp('missing')],
        convos: [_oneToOne()],
        members: {'aaa-member', 'self-dev', 'peer-dev'},
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await pumpEventQueue();
      expect(welcomesTo('missing'), hasLength(1));
    });

    test('a member further down stands down if the first added it meanwhile',
        () async {
      notifier.ownDeviceRankStep = const Duration(milliseconds: 1);
      await connectWith(
        devices: [
          _device('aaa-member'),
          _device('self-dev'),
          _device('missing'),
        ],
        kps: [_kp('missing')],
        convos: [_oneToOne()],
        members: {'aaa-member', 'self-dev', 'peer-dev'},
      );
      crypto.members = {'aaa-member', 'self-dev', 'missing', 'peer-dev'};
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await pumpEventQueue();
      expect(welcomesTo('missing'), isEmpty);
    });

    test('a device outside the group adds nobody', () async {
      await connectWith(
        devices: [_device('self-dev'), _device('other')],
        kps: [_kp('other')],
        convos: [_oneToOne()],
        members: {'other', 'peer-dev'},
      );
      expect(welcomesTo('other'), isEmpty);
    });

    test('a device with no group here adds nobody', () async {
      await connectWith(
        devices: [_device('self-dev'), _device('other')],
        kps: [_kp('other')],
        convos: [_oneToOne()],
        members: null,
      );
      expect(welcomesTo('other'), isEmpty);
    });

    test('the second add tells the device the first add brought in', () async {
      await connectWith(
        devices: [_device('self-dev'), _device('a-missing'), _device('b-missing')],
        kps: [_kp('a-missing'), _kp('b-missing')],
        convos: [_oneToOne()],
      );
      final commitsToA = api.submittedMessages.where((p) =>
          p.envelopeType == EnvelopeType.mlsHandshake &&
          p.recipientDeviceId == 'a-missing');
      expect(commitsToA, hasLength(1));
    });

    test('a device another of ours already added is not added again', () async {
      await connectWith(
        devices: [_device('self-dev'), _device('missing')],
        kps: [_kp('missing')],
        convos: [_oneToOne()],
        members: {'self-dev', 'peer-dev'},
      );
      final welcomes = welcomesTo('missing').length;
      crypto.members = {'self-dev', 'missing', 'peer-dev'};
      supervisor.emitReconnected();
      await pumpEventQueue();
      expect(welcomesTo('missing'), hasLength(welcomes));
    });

    test('the Commit goes only to devices really in the group', () async {
      api.peerDevices = const [
        AccountDevice(deviceId: 'peer-dev'),
        AccountDevice(deviceId: 'peer-left-out'),
      ];
      await connectWith(
        devices: [_device('self-dev'), _device('missing')],
        kps: [_kp('missing')],
        convos: [_oneToOne()],
      );
      final commits = api.submittedMessages
          .where((p) => p.envelopeType == EnvelopeType.mlsHandshake)
          .map((p) => p.recipientDeviceId);
      expect(commits, ['peer-dev']);
    });
  });

  group('a device that comes back into the group', () {
    Future<void> sweepAgain() async {
      supervisor.emitReconnected();
      await pumpEventQueue();
    }

    List<SubmitMessagePayload> historyTo(String deviceId) => api
        .submittedMessages
        .where((p) =>
            p.envelopeType == EnvelopeType.mlsApplication &&
            p.recipientDeviceId == deviceId)
        .toList();

    setUp(() async {
      final c = _oneToOne();
      await database.open(masterKeyHex: 'k');
      await database.upsertConversation(c);
      await database.upsertMessages(c.id, [
        ChatMessage(
          envelopeId: 'sent-while-it-was-out',
          conversationId: c.id,
          senderDeviceId: 'peer-dev',
          body: 'you missed this',
          serverTs: DateTime.utc(2026, 11, 7),
          mine: false,
        ),
      ]);
    });

    test('gets the history it missed', () async {
      await connectWith(
        devices: [_device('self-dev'), _device('sibling')],
        convos: [_oneToOne()],
        members: {'self-dev', 'peer-dev'},
      );
      crypto.members = {'self-dev', 'sibling', 'peer-dev'};
      await sweepAgain();
      expect(historyTo('sibling'), hasLength(1));
    });

    test('the history includes what this device sent itself', () async {
      final c = _oneToOne();
      await database.upsertMessages(c.id, [
        ChatMessage(
          envelopeId: 'sent-by-me',
          conversationId: c.id,
          senderDeviceId: 'self-dev',
          body: 'I sent this',
          serverTs: DateTime.utc(2026, 11, 7, 1),
          mine: true,
          outboxId: '',
        ),
      ]);
      await connectWith(
        devices: [_device('self-dev'), _device('sibling')],
        convos: [_oneToOne()],
        members: {'self-dev', 'peer-dev'},
      );
      crypto.members = {'self-dev', 'sibling', 'peer-dev'};
      await sweepAgain();
      final body = utf8.decode(historyTo('sibling').single.ciphertext);
      expect(body, contains('I sent this'));
    });

    test('gets nothing from a device that is not first in line', () async {
      await connectWith(
        devices: [_device('aaa-other'), _device('self-dev'), _device('sibling')],
        convos: [_oneToOne()],
        members: {'aaa-other', 'self-dev', 'peer-dev'},
      );
      crypto.members = {'aaa-other', 'self-dev', 'sibling', 'peer-dev'};
      await sweepAgain();
      expect(historyTo('sibling'), isEmpty);
    });

    test('the device that came back is not the one asked to replay', () async {
      await connectWith(
        devices: [_device('aaa-back'), _device('self-dev')],
        convos: [_oneToOne()],
        members: {'self-dev', 'peer-dev'},
      );
      crypto.members = {'aaa-back', 'self-dev', 'peer-dev'};
      await sweepAgain();
      expect(historyTo('aaa-back'), hasLength(1));
    });

    test('a device that never left gets no replay', () async {
      await connectWith(
        devices: [_device('self-dev'), _device('sibling')],
        convos: [_oneToOne()],
        members: {'self-dev', 'sibling', 'peer-dev'},
      );
      await sweepAgain();
      expect(historyTo('sibling'), isEmpty);
    });
  });

  test('a device whose packages arrive after the link is added without a reconnect',
      () async {
    notifier.ownDeviceNoPackageWaits = const [Duration(milliseconds: 1)];
    await connectWith(
      devices: [_device('self-dev'), _device('missing')],
      kps: const [],
      convos: [_oneToOne()],
    );
    api.deviceKeyPackages = [_kp('missing')];
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await pumpEventQueue();
    expect(welcomesTo('missing'), hasLength(1));
  });

  test('a failed package lookup is retried without waiting for a reconnect',
      () async {
    notifier.ownDeviceNoPackageWaits = const [Duration(milliseconds: 1)];
    api.failNextKpFetch = Exception('connection dropped');
    await connectWith(
      devices: [_device('self-dev'), _device('missing')],
      kps: [_kp('missing')],
      convos: [_oneToOne()],
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await pumpEventQueue();
    expect(welcomesTo('missing'), hasLength(1));
  });

  group('a device with no key package to add it with', () {
    setUp(() async {
      await connectWith(
        devices: [_device('self-dev'), _device('missing')],
        kps: const [],
        convos: [_oneToOne()],
      );
    });

    test('is added once the server says the device list changed', () async {
      api.deviceKeyPackages = [_kp('missing')];
      ws.pushDevicesChanged();
      await pumpEventQueue();
      expect(welcomesTo('missing'), hasLength(1));
    });

    test('does not burn more packages on the next sweep', () async {
      final fetches = api.deviceKpFetches;
      supervisor.emitReconnected();
      await pumpEventQueue();
      expect(api.deviceKpFetches, fetches);
    });
  });

  group('groups', () {
    test('the adder sends the new device a Welcome for each MLS group',
        () async {
      await connectWith(
        devices: [_device('self-dev'), _device('new-1', linkedBy: 'self-dev')],
        kps: [_kp('new-1')],
        convos: [_group()],
      );
      expect(welcomesTo('new-1').where((p) => p.conversationId == 'group:g1'),
          hasLength(1));
    });

    test('a device the roster lists but the group lost is added back', () async {
      final g = _group();
      await connectWith(
        devices: [_device('self-dev'), _device('new-1')],
        kps: [_kp('new-1')],
        convos: [
          g.copyWith(members: [...g.members, _member('self-acc', 'new-1', isSelf: true)])
        ],
      );
      expect(welcomesTo('new-1'), hasLength(1));
    });

    test('adding back a listed device keeps one roster row', () async {
      final g = _group();
      await connectWith(
        devices: [_device('self-dev'), _device('new-1')],
        kps: [_kp('new-1')],
        convos: [
          g.copyWith(members: [...g.members, _member('self-acc', 'new-1', isSelf: true)])
        ],
      );
      final members = notifier.conversation('group:g1')!.members;
      expect(members.where((m) => m.deviceId == 'new-1'), hasLength(1));
    });

    test('existing member devices receive the Commit', () async {
      await connectWith(
        devices: [_device('self-dev'), _device('new-1', linkedBy: 'self-dev')],
        kps: [_kp('new-1')],
        convos: [_group()],
      );
      expect(
          api.submittedMessages.where((p) =>
              p.envelopeType == EnvelopeType.mlsHandshake &&
              p.recipientDeviceId == 'peer-dev'),
          hasLength(1));
    });

    test('the new device is added to the group roster', () async {
      await connectWith(
        devices: [_device('self-dev'), _device('new-1', linkedBy: 'self-dev')],
        kps: [_kp('new-1')],
        convos: [_group()],
      );
      final members = notifier.conversation('group:g1')!.members;
      expect(members.where((m) => m.deviceId == 'new-1' && m.isSelf),
          hasLength(1));
    });

    test('a group that really holds the device is left alone', () async {
      await connectWith(
        devices: [_device('self-dev'), _device('new-1')],
        kps: [_kp('new-1')],
        convos: [_group()],
        members: {'self-dev', 'new-1', 'peer-dev'},
      );
      expect(welcomesTo('new-1'), isEmpty);
    });
  });
}
