import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:nanb_chat/core/crypto/add_member_result.dart';
import 'package:nanb_chat/core/crypto/conversation_crypto_state.dart';
import 'package:nanb_chat/core/crypto/crypto_bridge.dart';
import 'package:nanb_chat/core/crypto/decrypt_mls_result.dart';
import 'package:nanb_chat/core/models/api_error.dart';
import 'package:nanb_chat/core/models/jwt_session.dart';
import 'package:nanb_chat/core/network/api_client.dart';
import 'package:nanb_chat/core/secure_storage/secure_storage.dart';
import 'package:nanb_chat/features/onboarding/onboarding_notifier.dart';
import 'package:nanb_chat/features/onboarding/recovery_phrase.dart';
import 'package:nanb_chat/features/onboarding/recovery_phrase_storage.dart';
import 'package:nanb_chat/features/onboarding/restore_notifier.dart'
    show InvalidRecoveryPhraseException;
import 'package:nanb_chat/features/onboarding/session_repository.dart';

class _MockApi extends Mock implements ApiClient {}

class _RecordingCrypto implements CryptoBridge {
  @override
  Future<bool> consumeMlsStoreReset() async => false;

  final List<List<int>> mintedKeyPackages = [];
  int signCalls = 0;
  int mlsInitCalls = 0;
  int mintKeyPackagesBatchCalls = 0;
  int? lastMintKeyPackagesCount;
  bool failGenerate = false;
  bool failMlsInit = false;
  bool failMintKeyPackages = false;
  List<int>? lastSeed;
  IdentityHandle? _current;

  /// Fixed batch returned by mintKeyPackages — captured by tests that verify
  /// the list forwarded to publishKeyPackages.
  static const List<List<int>> _batchResult = [
    [0xAA, 0xBB],
    [0xCC, 0xDD],
  ];

  @override
  Future<IdentityHandle> generateIdentity({List<int>? seed}) async {
    if (failGenerate) {
      throw StateError('generate failed');
    }
    lastSeed = seed;
    final handle = IdentityHandle(
      id: 'id-1',
      publicKey: List<int>.filled(32, 7),
      x25519PublicKey: List<int>.filled(32, 11),
    );
    _current = handle;
    return handle;
  }

  @override
  Future<IdentityHandle?> currentIdentity() async => _current;

  @override
  Future<List<int>> signWithIdentity(IdentityHandle handle, List<int> payload) async {
    signCalls++;
    return List<int>.filled(64, 1);
  }

  @override
  Future<List<int>> mintKeyPackage(IdentityHandle handle) async {
    final kp = [for (var i = 0; i < 256; i++) (i + mintedKeyPackages.length) % 256];
    mintedKeyPackages.add(kp);
    return kp;
  }

  @override
  Future<ConversationCryptoState> initConversationCrypto({
    required String conversationId,
    required List<int> peerX25519PubKey,
  }) async => ConversationCryptoState(
        conversationId: conversationId,
        sendCounter: 0,
        sendChainKey: const [],
        recvCounter: 0,
        recvChainKey: const [],
      );

  @override
  Future<EncryptResult> encryptMessage({
    required ConversationCryptoState state,
    required List<int> plaintext,
  }) async => EncryptResult(ciphertext: plaintext, newState: state);

  @override
  Future<DecryptResult> decryptMessage({
    required ConversationCryptoState state,
    required List<int> ciphertext,
  }) async => DecryptResult(plaintext: ciphertext, newState: state);

  @override
  void clearConversationCrypto(String conversationId) {}

  @override
  Future<void> wipe() async {}

  @override
  Future<List<int>?> rawIdentitySeed() async => List<int>.filled(32, 0);

  @override
  Future<void> mlsInit() async {
    mlsInitCalls++;
    if (failMlsInit) throw StateError('mlsInit failed');
  }

  String? ensuredClientDeviceId;

  @override
  Future<void> mlsEnsureClient(String deviceId) async {
    ensuredClientDeviceId = deviceId;
  }

  @override
  Future<void> mlsInitReadOnly() async {}

  int mlsWipeCalls = 0;

  @override
  Future<void> mlsWipe() async {
    mlsWipeCalls++;
  }

  @override
  Future<List<List<int>>> mintKeyPackages({int count = 100}) async {
    mintKeyPackagesBatchCalls++;
    lastMintKeyPackagesCount = count;
    if (failMintKeyPackages) throw StateError('mintKeyPackages failed');
    return _batchResult;
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
  Future<String> processWelcome(List<int> welcomeBytes) async => 'stub-group';

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

void main() {
  setUpAll(() {
    registerFallbackValue(CreateAccountPayload(
      username: 'x',
      identityPubKey: const [],
      devicePubKey: const [],
      signedClaim: const [],
      keyPackages: const [],
    ));
    // Fallback for publishKeyPackages(List<List<int>>).
    registerFallbackValue(<List<int>>[]);
  });

  group('OnboardingNotifier', () {
    late _MockApi api;
    late _RecordingCrypto crypto;
    late SecureStorageInMemory storage;
    late SessionRepository sessions;
    late OnboardingNotifier notifier;

    setUp(() {
      api = _MockApi();
      crypto = _RecordingCrypto();
      storage = SecureStorageInMemory();
      sessions = SessionRepository(storage);
      notifier = OnboardingNotifier(
        apiClient: api,
        crypto: crypto,
        sessions: sessions,
        phraseStorage: RecoveryPhraseStorage(storage),
      );
    });

    test('createAccount happy path persists session and returns recovery phrase', () async {
      const session = JwtSession(
        accountId: 'acc-1',
        deviceId: 'dev-1',
        jwt: 'jwt-token',
        username: 'nass',
      );
      when(() => api.createAccount(any())).thenAnswer((_) async => session);
      when(() => api.publishKeyPackages(any())).thenAnswer((_) async => 2);

      final res = await notifier.createAccount(username: 'nass');

      expect(res.session, equals(session));
      expect(res.recoveryPhrase.split(' ').length, equals(12));
      // Legacy ratchet KPs are no longer minted into the create payload —
      // CoreCrypto can't parse them, so they only poisoned migrations.
      expect(crypto.mintedKeyPackages, isEmpty);
      expect(crypto.signCalls, greaterThanOrEqualTo(1));
      expect(await sessions.current(), equals(session));
    });

    test('createAccount initializes the MLS client with the device id', () async {
      const session = JwtSession(accountId: 'a', deviceId: 'dev-42', jwt: 'j', username: 'nass');
      when(() => api.createAccount(any())).thenAnswer((_) async => session);
      when(() => api.publishKeyPackages(any())).thenAnswer((_) async => 2);

      await notifier.createAccount(username: 'nass');
      expect(crypto.ensuredClientDeviceId, equals('dev-42'));
    });

    test('createAccount propagates ApiError on username taken', () async {
      when(() => api.createAccount(any())).thenThrow(
        const ApiError(code: 'username_taken', message: 'taken', statusCode: 409),
      );

      await expectLater(
        () => notifier.createAccount(username: 'nass'),
        throwsA(isA<ApiError>().having((e) => e.code, 'code', 'username_taken')),
      );
      // Session NOT persisted on failure.
      expect(await sessions.current(), isNull);
    });

    test('createAccount wipes the MLS store when the create call fails', () async {
      // A failed create leaves CoreCrypto opened under this attempt's seed; a
      // retry generates a new seed but mlsInit() would early-return, minting
      // future key packages against the stale store. The store must be wiped
      // so the retry re-opens cleanly.
      when(() => api.createAccount(any())).thenThrow(
        const ApiError(
            code: 'identity_key_taken', message: 'taken', statusCode: 409),
      );

      await expectLater(
        () => notifier.createAccount(username: 'nass'),
        throwsA(isA<ApiError>()),
      );
      expect(crypto.mlsWipeCalls, equals(1));
    });

    test('createAccount propagates crypto errors', () async {
      crypto.failGenerate = true;
      expect(
        () => notifier.createAccount(username: 'nass'),
        throwsA(isA<StateError>()),
      );
      verifyNever(() => api.createAccount(any()));
    });

    test('createAccount calls mlsInit after generateIdentity succeeds', () async {
      const session = JwtSession(accountId: 'acc-1', deviceId: 'dev-1', jwt: 'jwt-token', username: 'nass');
      when(() => api.createAccount(any())).thenAnswer((_) async => session);
      when(() => api.publishKeyPackages(any())).thenAnswer((_) async => 2);

      await notifier.createAccount(username: 'nass');

      // Twice: once before createAccount, then again inside the post-create
      // MLS block, which re-runs the (idempotent) open as the retry for a
      // store that failed to open the first time.
      expect(crypto.mlsInitCalls, equals(2));
    });

    test('createAccount still creates the account when mlsInit fails', () async {
      // A CoreCrypto store that won't open must NOT block sign-up. It used to:
      // the failure threw straight out of createAccount, so a user whose store
      // was unopenable could not make an account at all. MLS degrades to the
      // ratchet and the store is retried on every foreground instead.
      const session = JwtSession(accountId: 'acc-1', deviceId: 'dev-1', jwt: 'jwt-tok', username: 'nass');
      when(() => api.createAccount(any())).thenAnswer((_) async => session);
      crypto.failMlsInit = true;

      final result = await notifier.createAccount(username: 'nass');

      expect(result.session, equals(session));
    });

    test('username claim payload starts with the canonical prefix', () {
      final bytes = OnboardingNotifier.usernameClaimPayload('nass', [1, 2, 3]);
      const prefix = 'nanb-username-claim-v1:';
      final got = String.fromCharCodes(bytes.sublist(0, prefix.length));
      expect(got, equals(prefix));
    });

    test('username claim payload separates username from pubkey with |', () {
      final bytes = OnboardingNotifier.usernameClaimPayload('xy', [9]);
      // ...prefix + 'xy' + '|' + pubkey bytes
      final pipeIndex = bytes.indexOf(0x7C);
      expect(pipeIndex, greaterThan(0));
      expect(bytes[pipeIndex + 1], equals(9));
    });

    test('createAccount seeds identity from the recovery phrase', () async {
      const sess = JwtSession(accountId: 'a', deviceId: 'd', jwt: 'j', username: 'nass');
      when(() => api.createAccount(any())).thenAnswer((_) async => sess);
      when(() => api.publishKeyPackages(any())).thenAnswer((_) async => 2);

      final res = await notifier.createAccount(username: 'nass');

      // Identity was derived from the BIP-39 phrase, not random.
      expect(crypto.lastSeed, isNotNull);
      expect(crypto.lastSeed!.length, equals(64)); // BIP-39 PBKDF2 output

      // Verify the persisted phrase is the one that derived the seed (so a
      // future restore will produce the same identity).
      final derived = RecoveryPhrase.toSeed(res.recoveryPhrase);
      expect(crypto.lastSeed, equals(derived));
    });

    test('createAccount uses a caller-supplied custom phrase (normalized)', () async {
      const sess = JwtSession(accountId: 'a', deviceId: 'd', jwt: 'j', username: 'nass');
      when(() => api.createAccount(any())).thenAnswer((_) async => sess);
      when(() => api.publishKeyPackages(any())).thenAnswer((_) async => 2);

      final res = await notifier.createAccount(
        username: 'nass',
        recoveryPhrase:
            '  My TWELVE Word Custom  Phrase\nAbout GREEN Turtles Today '
            'Under Calm Water ',
      );

      // Normalized form is returned + persisted, and the seed derives from it.
      const normalized = 'my twelve word custom phrase about green turtles '
          'today under calm water';
      expect(res.recoveryPhrase, equals(normalized));
      expect(crypto.lastSeed, equals(RecoveryPhrase.toSeed(normalized)));
      final stored = await RecoveryPhraseStorage(storage).read();
      expect(stored, equals(normalized));
    });

    test('createAccount rejects a weak custom phrase before any network call',
        () async {
      // 12 words / 8 distinct single letters — passes the old count-only gate
      // but is trivially low-entropy. The notifier (not just the UI) must be
      // the real gate, so this never derives a key or reaches the server.
      await expectLater(
        () => notifier.createAccount(
          username: 'nass',
          recoveryPhrase: 'a b c d e f g h a a a a',
        ),
        throwsA(isA<InvalidRecoveryPhraseException>()),
      );
      expect(crypto.lastSeed, isNull); // no key derivation
      verifyNever(() => api.createAccount(any())); // no server call
      expect(await sessions.current(), isNull); // nothing persisted
    });

    test('createAccount accepts a strong custom phrase', () async {
      const sess = JwtSession(
          accountId: 'a', deviceId: 'd', jwt: 'j', username: 'nass');
      when(() => api.createAccount(any())).thenAnswer((_) async => sess);
      when(() => api.publishKeyPackages(any())).thenAnswer((_) async => 2);

      const strong = 'lantern voyage crimson pebble orbit thicket meadow '
          'anchor quiver saddle bramble twilight';
      final res =
          await notifier.createAccount(username: 'nass', recoveryPhrase: strong);

      expect(res.recoveryPhrase, equals(strong));
      expect(await sessions.current(), equals(sess));
    });

    test('createAccount persists the recovery phrase for later reveal', () async {
      const sess = JwtSession(accountId: 'a', deviceId: 'd', jwt: 'j', username: 'nass');
      when(() => api.createAccount(any())).thenAnswer((_) async => sess);
      when(() => api.publishKeyPackages(any())).thenAnswer((_) async => 2);

      final res = await notifier.createAccount(username: 'nass');
      final stored = await RecoveryPhraseStorage(storage).read();
      expect(stored, equals(res.recoveryPhrase));
    });

    // ─── mintKeyPackages + publishKeyPackages ─────────────────────────────────

    test('createAccount calls mintKeyPackages(count: 100) after account creation succeeds',
        () async {
      const sess = JwtSession(accountId: 'a', deviceId: 'd', jwt: 'j', username: 'nass');
      when(() => api.createAccount(any())).thenAnswer((_) async => sess);
      when(() => api.publishKeyPackages(any())).thenAnswer((_) async => 2);

      await notifier.createAccount(username: 'nass');

      expect(crypto.mintKeyPackagesBatchCalls, equals(1));
      expect(crypto.lastMintKeyPackagesCount, equals(100));
    });

    test('createAccount forwards mintKeyPackages result to publishKeyPackages', () async {
      const sess = JwtSession(accountId: 'a', deviceId: 'd', jwt: 'j', username: 'nass');
      List<List<int>>? capturedPackages;
      when(() => api.createAccount(any())).thenAnswer((_) async => sess);
      when(() => api.publishKeyPackages(any())).thenAnswer((inv) async {
        capturedPackages = inv.positionalArguments.first as List<List<int>>;
        return capturedPackages!.length;
      });

      await notifier.createAccount(username: 'nass');

      expect(capturedPackages, equals(_RecordingCrypto._batchResult));
    });

    test('createAccount succeeds even when publishKeyPackages throws', () async {
      const sess = JwtSession(accountId: 'a', deviceId: 'd', jwt: 'j', username: 'nass');
      when(() => api.createAccount(any())).thenAnswer((_) async => sess);
      when(() => api.publishKeyPackages(any())).thenThrow(
        const ApiError(code: 'network', message: 'timeout', statusCode: null),
      );

      // Should not throw — publish failure is non-fatal.
      final res = await notifier.createAccount(username: 'nass');
      expect(res.session, equals(sess));
      expect(await sessions.current(), equals(sess));
    });

    test('createAccount succeeds even when mintKeyPackages throws', () async {
      const sess = JwtSession(accountId: 'a', deviceId: 'd', jwt: 'j', username: 'nass');
      when(() => api.createAccount(any())).thenAnswer((_) async => sess);
      // publishKeyPackages stub not set up — if code reaches it, test fails.
      crypto.failMintKeyPackages = true;

      final res = await notifier.createAccount(username: 'nass');
      expect(res.session, equals(sess));
    });
  });
}
