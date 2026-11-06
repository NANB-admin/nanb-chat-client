import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/core/crypto/add_member_result.dart';
import 'package:nanb_chat/core/crypto/conversation_crypto_state.dart';
import 'package:nanb_chat/core/crypto/crypto_bridge.dart';
import 'package:nanb_chat/core/crypto/decrypt_mls_result.dart';
import 'package:nanb_chat/core/crypto/mls_exceptions.dart';
import 'package:nanb_chat/core/models/account.dart';
import 'package:nanb_chat/core/models/turn_credentials.dart';
import 'package:nanb_chat/core/models/device.dart';
import 'package:nanb_chat/core/models/envelope.dart';
import 'package:nanb_chat/core/models/jwt_session.dart';
import 'package:nanb_chat/core/models/report_request.dart';
import 'package:nanb_chat/core/network/api_client.dart';
import 'package:nanb_chat/features/chat/mls_migrator.dart';
import 'package:nanb_chat/features/chat/models/conversation.dart';
import 'package:nanb_chat/features/chat/models/crypto_mode.dart';

// ─── Test fakes ──────────────────────────────────────────────────────────────

/// Minimal CryptoBridge recording only the calls [MlsMigrator] makes.
/// All other methods throw [UnsupportedError].
class _RecordingBridge implements CryptoBridge {
  @override
  Future<bool> consumeMlsStoreReset() async => false;

  final List<String> calls = [];

  // Configurable results for the methods the migrator uses.
  List<int> encryptResult = [42];
  AddMemberResult addMemberResult = AddMemberResult(welcome: [99], commit: [88]);
  String createGroupResult = 'convo-1'; // matches convo.id by default

  /// When set, the NEXT createGroup call throws this (then clears) —
  /// simulates an orphaned half-created group blocking the first attempt.
  Object? createGroupErrorOnce;

  /// When set, every addMember call throws this — simulates a migration
  /// failing AFTER the local group was created.
  Object? addMemberError;

  @override
  Future<void> wipeGroup(String groupId) async {
    calls.add('wipeGroup:$groupId');
  }

  @override
  Future<List<int>> encrypt({
    required String groupId,
    required List<int> plaintext,
  }) async {
    calls.add('encrypt:$groupId');
    return encryptResult;
  }

  @override
  Future<String> createGroup({required String conversationId}) async {
    calls.add('createGroup:$conversationId');
    final err = createGroupErrorOnce;
    if (err != null) {
      createGroupErrorOnce = null;
      throw err;
    }
    return createGroupResult;
  }

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
    calls.add('addMember:$groupId');
    final err = addMemberError;
    if (err != null) throw err;
    return addMemberResult;
  }

  // ─── Unused methods — throw UnsupportedError ─────────────────────────────
  @override
  Future<IdentityHandle> generateIdentity({List<int>? seed}) =>
      throw UnsupportedError('not used by migrator');
  @override
  Future<IdentityHandle?> currentIdentity() =>
      throw UnsupportedError('not used by migrator');
  @override
  Future<List<int>> signWithIdentity(IdentityHandle handle, List<int> payload) =>
      throw UnsupportedError('not used by migrator');
  @override
  Future<List<int>> mintKeyPackage(IdentityHandle handle) =>
      throw UnsupportedError('not used by migrator');
  @override
  Future<ConversationCryptoState> initConversationCrypto({
    required String conversationId,
    required List<int> peerX25519PubKey,
  }) =>
      throw UnsupportedError('not used by migrator');
  @override
  Future<EncryptResult> encryptMessage({
    required ConversationCryptoState state,
    required List<int> plaintext,
  }) =>
      throw UnsupportedError('not used by migrator');
  @override
  Future<DecryptResult> decryptMessage({
    required ConversationCryptoState state,
    required List<int> ciphertext,
  }) =>
      throw UnsupportedError('not used by migrator');
  @override
  void clearConversationCrypto(String conversationId) =>
      throw UnsupportedError('not used by migrator');
  @override
  Future<void> wipe() => throw UnsupportedError('not used by migrator');
  @override
  Future<List<int>?> rawIdentitySeed() =>
      throw UnsupportedError('not used by migrator');
  @override
  Future<void> mlsInit() => throw UnsupportedError('not used by migrator');
  @override
  Future<void> mlsEnsureClient(String deviceId) async {}

  @override
  Future<void> mlsInitReadOnly() => throw UnsupportedError('not used by migrator');
  @override
  Future<void> mlsWipe() => throw UnsupportedError('not used by migrator');
  @override
  Future<List<List<int>>> mintKeyPackages({int count = 100}) =>
      throw UnsupportedError('not used by migrator');
  @override
  Future<String> processWelcome(List<int> welcomeBytes) =>
      throw UnsupportedError('not used by migrator');
  @override
  Future<void> processCommit({
    required String groupId,
    required List<int> commitBytes,
  }) =>
      throw UnsupportedError('not used by migrator');
  @override
  Future<int> currentEpoch(String groupId) =>
      throw UnsupportedError('not used by migrator');
  @override
  Future<List<int>> decrypt({
    required String groupId,
    required List<int> ciphertext,
  }) =>
      throw UnsupportedError('not used by migrator');
  @override
  Future<String> replaceGroup({
    required String localGroupId,
    required List<int> foreignWelcome,
  }) =>
      throw UnsupportedError('not used by migrator');
  @override
  Future<List<int>> removeMember({
    required String groupId,
    required String targetDeviceId,
  }) =>
      throw UnsupportedError('not used by migrator');

  @override
  Future<DecryptMlsResult> decryptAndInspect({
    required String groupId,
    required List<int> ciphertext,
  }) =>
      throw UnsupportedError('not used by migrator');
}

/// Minimal ApiClient recording only lookupKeyPackage calls.
/// All other methods throw [UnsupportedError].
class _RecordingApi implements ApiClient {
  FetchKeyPackageResult? kpResult;
  Object? lookupError;
  final List<String> calls = [];

  @override
  Future<FetchKeyPackageResult> lookupKeyPackage(String username) async {
    calls.add('lookupKeyPackage:$username');
    if (lookupError != null) throw lookupError!;
    return kpResult!;
  }

  // ─── Unused methods — throw UnsupportedError ─────────────────────────────
  @override
  Future<List<DeviceKeyPackageResult>> lookupDeviceKeyPackages(
          String username) =>
      throw UnsupportedError('not used by migrator');
  @override
  void setBearerToken(String? jwt) => throw UnsupportedError('not used by migrator');
  @override
  Future<JwtSession> createAccount(CreateAccountPayload payload) =>
      throw UnsupportedError('not used by migrator');
  @override
  Future<Account> lookupAccount(String username) =>
      throw UnsupportedError('not used by migrator');
  @override
  Future<TurnCredentials> fetchTurnCredentials() =>
      throw UnsupportedError('not used by migrator');
  @override
  Future<Account> lookupAccountById(String accountId) =>
      throw UnsupportedError('not used by migrator');
  @override
  Future<void> revokeDevice(String deviceId) =>
      throw UnsupportedError('not used by migrator');
  @override
  Future<UsernameAvailability> checkUsername(String username) =>
      throw UnsupportedError('not used by migrator');
  @override
  Future<Account> lookupAccountByDevice(String deviceId) =>
      throw UnsupportedError('not used by migrator');
  @override
  Future<List<Device>> listDevices() =>
      throw UnsupportedError('not used by migrator');
  @override
  Future<void> reportSealedCapability({List<int> x25519PubKey = const []}) =>
      throw UnsupportedError('not used by migrator');
  @override
  Future<void> reportAccessKeyCommitment(List<int> commitment) =>
      throw UnsupportedError('not used by migrator');
  @override
  Future<SubmitMessageResult> submitSealedUnauthenticated(
          SubmitMessagePayload payload, List<int> accessKey) =>
      throw UnsupportedError('not used by migrator');
  @override
  Future<void> updateProfile({String? displayName, String? avatarUrl}) =>
      throw UnsupportedError('not used by migrator');
  @override
  Future<LinkDeviceResult> linkDevice(LinkDevicePayload payload) =>
      throw UnsupportedError('not used by migrator');
  @override
  Future<PendingDevice> getPendingDevice(String devicePubKeyHex) =>
      throw UnsupportedError('not used by migrator');
  @override
  Future<ChallengeReply> requestChallenge({
    required String username,
    required String deviceId,
  }) =>
      throw UnsupportedError('not used by migrator');
  @override
  Future<JwtSession> submitSession({
    required String username,
    required String deviceId,
    required List<int> challenge,
    required List<int> signature,
  }) =>
      throw UnsupportedError('not used by migrator');
  @override
  Future<ChallengeReply> requestRestoreChallenge({required String username}) =>
      throw UnsupportedError('not used by migrator');
  @override
  Future<JwtSession> submitRestoreSession({
    required String username,
    required List<int> identityPubKey,
    required List<int> challenge,
    required List<int> signature,
    List<int> devicePubKey = const [],
    List<int> x25519PubKey = const [],
  }) =>
      throw UnsupportedError('not used by migrator');
  @override
  Future<SubmitMessageResult> submitMessage(SubmitMessagePayload payload) =>
      throw UnsupportedError('not used by migrator');
  @override
  Future<List<Envelope>> catchupMessages({
    DateTime? since,
    int? limit,
  }) =>
      throw UnsupportedError('not used by migrator');
  @override
  Future<int> ackMessages(List<String> envelopeIds) =>
      throw UnsupportedError('not used by migrator');
  @override
  Future<MediaUploadInit> initMediaUpload({
    required List<int> sha256,
    required int sizeBytes,
    required String mimeType,
    int? ttlSeconds,
    List<String>? authorizedAccountIds,
  }) =>
      throw UnsupportedError('not used by migrator');
  @override
  Future<MediaDownload> getMedia(String mediaId) =>
      throw UnsupportedError('not used by migrator');
  @override
  Future<void> putBytesToUrl({
    required String url,
    required List<int> bytes,
    required String mimeType,
  }) =>
      throw UnsupportedError('not used by migrator');
  @override
  Future<List<int>> getBytesFromUrl(String url) =>
      throw UnsupportedError('not used by migrator');
  @override
  Future<void> registerPushToken({
    required String platform,
    required String token,
  }) =>
      throw UnsupportedError('not used by migrator');
  @override
  Future<void> deletePushToken() =>
      throw UnsupportedError('not used by migrator');
  @override
  Future<void> deleteAccount() =>
      throw UnsupportedError('not used by migrator');
  @override
  Future<void> reportUser(ReportRequest request) =>
      throw UnsupportedError('not used by migrator');
  @override
  Future<int> publishKeyPackages(List<List<int>> packages, {bool reset = false}) =>
      throw UnsupportedError('not used by migrator');
  @override
  Future<int> keyPackageCount() =>
      throw UnsupportedError('not used by migrator');
  @override
  Future<Envelope> getEnvelopeById(String envelopeId) =>
      throw UnsupportedError('not used by migrator');
}

// ─── Helpers ─────────────────────────────────────────────────────────────────

const _convoId = 'convo-1';
const _peerDeviceId = 'peer-dev-1';
const _peerUsername = 'alice';

Conversation _ratchetConvo() => const Conversation(
      id: _convoId,
      peerUsername: _peerUsername,
      peerAccountId: 'alice-acc',
      peerDeviceId: _peerDeviceId,
      peerIdentityPubKey: [],
      messages: [],
      unreadCount: 0,
      cryptoMode: CryptoMode.ratchet,
    );

Conversation _mlsConvo() => const Conversation(
      id: _convoId,
      peerUsername: _peerUsername,
      peerAccountId: 'alice-acc',
      peerDeviceId: _peerDeviceId,
      peerIdentityPubKey: [],
      messages: [],
      unreadCount: 0,
      cryptoMode: CryptoMode.mls,
    );

FetchKeyPackageResult _kpResult() => const FetchKeyPackageResult(
      keyPackage: [1, 2, 3],
      replenishNeeded: false,
      remainingForUser: 50,
    );

const _plaintext = [10, 20, 30];

// ─── Tests ───────────────────────────────────────────────────────────────────

void main() {
  late _RecordingBridge bridge;
  late _RecordingApi api;
  late List<int> legacyCiphertext;

  MlsMigrator buildMigrator() => MlsMigrator(
        bridge: bridge,
        apiClient: api,
        legacyEncryptOnRatchet: (convo, plaintext) async => legacyCiphertext,
      );

  setUp(() {
    bridge = _RecordingBridge();
    api = _RecordingApi();
    legacyCiphertext = [55, 66, 77];
  });

  test('migrates on first send: happy path', () async {
    bridge.createGroupResult = _convoId; // §7.3 satisfied
    bridge.encryptResult = [42];
    bridge.addMemberResult = AddMemberResult(welcome: [99], commit: [88]);
    api.kpResult = _kpResult();

    final migrator = buildMigrator();
    final result = await migrator.encryptForSend(
      convo: _ratchetConvo(),
      plaintext: _plaintext,
    );

    expect(result.newMode, CryptoMode.mls);
    expect(result.envelopeType, 'mls_application');
    expect(result.ciphertext, [42]);
    expect(result.welcomeBytes, [99]);
    expect(result.welcomeRecipientDeviceId, _peerDeviceId);
    expect(api.calls, contains('lookupKeyPackage:$_peerUsername'));
    expect(bridge.calls, contains('createGroup:$_convoId'));
    expect(bridge.calls, contains('addMember:$_convoId'));
    expect(bridge.calls, contains('encrypt:$_convoId'));
  });

  test('keeps on ratchet: peer account not found (404)', () async {
    api.lookupError = const AccountNotFoundException('alice not found');

    final migrator = buildMigrator();
    final result = await migrator.encryptForSend(
      convo: _ratchetConvo(),
      plaintext: _plaintext,
    );

    expect(result.newMode, CryptoMode.ratchet);
    expect(result.envelopeType, 'text_legacy');
    expect(result.ciphertext, legacyCiphertext);
    expect(result.welcomeBytes, isNull);
    expect(result.welcomeRecipientDeviceId, isNull);
  });

  test('keeps on ratchet: peer key packages exhausted (410)', () async {
    api.lookupError = const KeyPackageExhaustedException('no kps left');

    final migrator = buildMigrator();
    final result = await migrator.encryptForSend(
      convo: _ratchetConvo(),
      plaintext: _plaintext,
    );

    expect(result.newMode, CryptoMode.ratchet);
    expect(result.envelopeType, 'text_legacy');
    expect(result.ciphertext, legacyCiphertext);
    expect(result.welcomeBytes, isNull);
    expect(result.welcomeRecipientDeviceId, isNull);
  });

  test('keeps on ratchet: unexpected network error', () async {
    api.lookupError = Exception('connection timeout');

    final migrator = buildMigrator();
    final result = await migrator.encryptForSend(
      convo: _ratchetConvo(),
      plaintext: _plaintext,
    );

    expect(result.newMode, CryptoMode.ratchet);
    expect(result.envelopeType, 'text_legacy');
    expect(result.ciphertext, legacyCiphertext);
    expect(result.welcomeBytes, isNull);
  });

  test('mls-mode convo: skips migration and goes straight to bridge.encrypt', () async {
    bridge.encryptResult = [77];

    final migrator = buildMigrator();
    final result = await migrator.encryptForSend(
      convo: _mlsConvo(),
      plaintext: _plaintext,
    );

    expect(result.newMode, CryptoMode.mls);
    expect(result.envelopeType, 'mls_application');
    expect(result.ciphertext, [77]);
    expect(result.welcomeBytes, isNull);
    // Confirm no migration calls were made.
    expect(api.calls, isEmpty);
    expect(bridge.calls, isNot(contains('createGroup:$_convoId')));
    expect(bridge.calls, isNot(contains('addMember:$_convoId')));
    expect(bridge.calls, contains('encrypt:$_convoId'));
  });

  test(
      'orphan cleanup: addMember failure wipes the half-created group '
      'and falls back to ratchet', () async {
    bridge.createGroupResult = _convoId;
    bridge.addMemberError = const MlsArgumentException('bad kp');
    api.kpResult = _kpResult();

    final migrator = buildMigrator();
    final result = await migrator.encryptForSend(
      convo: _ratchetConvo(),
      plaintext: _plaintext,
    );

    // Fell back to ratchet — but ONLY after wiping the orphan, so the
    // conversation isn't poisoned for the retry / the peer's Welcome.
    expect(result.newMode, CryptoMode.ratchet);
    expect(result.envelopeType, 'text_legacy');
    expect(bridge.calls, contains('wipeGroup:$_convoId'));
    // The wipe happens both inside the failed attempt and via the
    // MlsException retry path; the LAST call must still be a wipe (the
    // retry's own failure cleanup), never a dangling createGroup.
    expect(bridge.calls.last, 'wipeGroup:$_convoId');
  });

  test(
      'orphan self-heal: createGroup blocked by a stale group is wiped '
      'and the migration retried successfully', () async {
    bridge.createGroupResult = _convoId;
    bridge.createGroupErrorOnce =
        const MlsArgumentException('conversation already exists');
    api.kpResult = _kpResult();

    final migrator = buildMigrator();
    final result = await migrator.encryptForSend(
      convo: _ratchetConvo(),
      plaintext: _plaintext,
    );

    // The orphan was wiped and the SAME fetched key package reused — the
    // send migrates to MLS instead of being stuck on ratchet forever.
    expect(result.newMode, CryptoMode.mls);
    expect(result.envelopeType, 'mls_application');
    expect(result.welcomeBytes, [99]);
    expect(bridge.calls, contains('wipeGroup:$_convoId'));
    // Exactly one key-package fetch — the retry reuses it.
    expect(
      api.calls.where((c) => c.startsWith('lookupKeyPackage')).length,
      1,
    );
  });

  test('§7.3 invariant: bridge.createGroup returning different id throws StateError',
      () async {
    bridge.createGroupResult = 'different-group-id'; // §7.3 violated
    api.kpResult = _kpResult();

    final migrator = buildMigrator();
    await expectLater(
      migrator.encryptForSend(
        convo: _ratchetConvo(),
        plaintext: _plaintext,
      ),
      throwsA(isA<StateError>().having(
        (e) => e.message,
        'message',
        contains('spec §7.3 violated'),
      )),
    );
  });

  group('deterministic migration (smaller account initiates)', () {
    MlsMigrator migratorAs(String myAccountId) => MlsMigrator(
          bridge: bridge,
          apiClient: api,
          myAccountId: myAccountId,
          legacyEncryptOnRatchet: (convo, plaintext) async => legacyCiphertext,
        );

    test('the LARGER account stays on ratchet and never initiates a group',
        () async {
      // peerAccountId is 'alice-acc'; 'bob-acc' > 'alice-acc' → we're the
      // follower → we must NOT migrate (so the two sides can't collide).
      api.kpResult = _kpResult();
      bridge.createGroupResult = _convoId;
      bridge.addMemberResult = AddMemberResult(welcome: [99], commit: [88]);

      final result = await migratorAs('bob-acc').encryptForSend(
        convo: _ratchetConvo(),
        plaintext: _plaintext,
      );

      expect(result.newMode, CryptoMode.ratchet);
      expect(result.envelopeType, 'text_legacy');
      expect(result.welcomeBytes, isNull);
      // No migration attempted — not even a key-package lookup.
      expect(api.calls, isEmpty);
      expect(bridge.calls, isNot(contains('createGroup:$_convoId')));
    });

    test('the SMALLER account initiates the migration', () async {
      // 'aaron-acc' < 'alice-acc' → we're the leader → we migrate.
      api.kpResult = _kpResult();
      bridge.createGroupResult = _convoId;
      bridge.encryptResult = [42];
      bridge.addMemberResult = AddMemberResult(welcome: [99], commit: [88]);

      final result = await migratorAs('aaron-acc').encryptForSend(
        convo: _ratchetConvo(),
        plaintext: _plaintext,
      );

      expect(result.newMode, CryptoMode.mls);
      expect(result.welcomeBytes, [99]);
      expect(bridge.calls, contains('createGroup:$_convoId'));
    });

    test('forceMigration overrides the rule for the larger account', () async {
      // The follower normally stays ratchet, but a re-establishment forces it
      // to rebuild the group regardless.
      api.kpResult = _kpResult();
      bridge.createGroupResult = _convoId;
      bridge.encryptResult = [42];
      bridge.addMemberResult = AddMemberResult(welcome: [99], commit: [88]);

      final result = await migratorAs('bob-acc').encryptForSend(
        convo: _ratchetConvo(),
        plaintext: _plaintext,
        forceMigration: true,
      );

      expect(result.newMode, CryptoMode.mls);
      expect(result.welcomeBytes, [99]);
      expect(bridge.calls, contains('createGroup:$_convoId'));
    });

    test('allowMigration false: the smaller account stays on ratchet', () async {
      api.kpResult = _kpResult();
      bridge.createGroupResult = _convoId;

      final result = await migratorAs('aaron-acc').encryptForSend(
        convo: _ratchetConvo(),
        plaintext: _plaintext,
        allowMigration: false,
      );

      expect(result.newMode, CryptoMode.ratchet);
    });

    test('allowMigration false: no group is created even when forced',
        () async {
      api.kpResult = _kpResult();
      bridge.createGroupResult = _convoId;

      await migratorAs('aaron-acc').encryptForSend(
        convo: _ratchetConvo(),
        plaintext: _plaintext,
        forceMigration: true,
        allowMigration: false,
      );

      expect(bridge.calls, isNot(contains('createGroup:$_convoId')));
    });

    test('migrateOnly: the larger account returns null (no group created)',
        () async {
      api.kpResult = _kpResult();
      bridge.createGroupResult = _convoId;
      bridge.addMemberResult = AddMemberResult(welcome: [99], commit: [88]);

      final w = await migratorAs('bob-acc').migrateOnly(_ratchetConvo());

      expect(w, isNull);
      expect(bridge.calls, isNot(contains('createGroup:$_convoId')));
    });
  });

  group('migrateOnly (eager warm-up)', () {
    test('migrates without sending content: group + Welcome, no encrypt',
        () async {
      bridge.createGroupResult = _convoId;
      bridge.addMemberResult = AddMemberResult(welcome: [99], commit: [88]);
      api.kpResult = _kpResult();

      final w = await buildMigrator().migrateOnly(_ratchetConvo());

      expect(w, isNotNull);
      expect(w!.welcome, [99]);
      expect(w.recipientDeviceId, _peerDeviceId);
      expect(bridge.calls, contains('createGroup:$_convoId'));
      expect(bridge.calls, contains('addMember:$_convoId'));
      // The whole point: NO message is encrypted/sent during warm-up.
      expect(bridge.calls, isNot(contains('encrypt:$_convoId')));
    });

    test('already MLS: returns null, touches nothing', () async {
      final w = await buildMigrator().migrateOnly(_mlsConvo());
      expect(w, isNull);
      expect(api.calls, isEmpty);
      expect(bridge.calls, isEmpty);
    });

    test('peer not upgraded (404): returns null, stays ratchet', () async {
      api.lookupError = const AccountNotFoundException('alice not found');
      expect(await buildMigrator().migrateOnly(_ratchetConvo()), isNull);
    });

    test('peer key packages exhausted (410): returns null', () async {
      api.lookupError = const KeyPackageExhaustedException('no kps left');
      expect(await buildMigrator().migrateOnly(_ratchetConvo()), isNull);
    });

    test('orphan self-heal: stale group wiped, retried, succeeds', () async {
      bridge.createGroupResult = _convoId;
      bridge.createGroupErrorOnce =
          const MlsArgumentException('conversation already exists');
      bridge.addMemberResult = AddMemberResult(welcome: [99], commit: [88]);
      api.kpResult = _kpResult();

      final w = await buildMigrator().migrateOnly(_ratchetConvo());

      expect(w, isNotNull);
      expect(w!.welcome, [99]);
      expect(bridge.calls, contains('wipeGroup:$_convoId'));
      // One key-package fetch — the retry reuses it (single-use safety).
      expect(api.calls.where((c) => c.startsWith('lookupKeyPackage')).length, 1);
    });

    test('addMember failure: wipes the orphan and returns null (no poison)',
        () async {
      bridge.createGroupResult = _convoId;
      bridge.addMemberError = const MlsArgumentException('bad kp');
      api.kpResult = _kpResult();

      final w = await buildMigrator().migrateOnly(_ratchetConvo());

      expect(w, isNull);
      expect(bridge.calls, contains('wipeGroup:$_convoId'));
      expect(bridge.calls.last, 'wipeGroup:$_convoId'); // never a dangling group
    });
  });
}
