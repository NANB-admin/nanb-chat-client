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
import 'package:nanb_chat/features/onboarding/login_notifier.dart';
import 'package:nanb_chat/features/onboarding/session_repository.dart';

class _MockApi extends Mock implements ApiClient {}

class _StubCrypto implements CryptoBridge {
  @override
  Future<Set<String>> groupMemberDeviceIds(String groupId) async => const {};

  @override
  Future<bool> consumeMlsStoreReset() async => false;

  bool failSign = false;
  int mlsInitCalls = 0;
  IdentityHandle? injected = const IdentityHandle(
    id: 'id-1',
    publicKey: [1, 2, 3],
    x25519PublicKey: [4, 5, 6],
  );

  @override
  Future<IdentityHandle> generateIdentity({List<int>? seed}) async {
    injected = const IdentityHandle(
      id: 'id-1',
      publicKey: [1, 2, 3],
      x25519PublicKey: [4, 5, 6],
    );
    return injected!;
  }

  @override
  Future<IdentityHandle?> currentIdentity() async => injected;

  @override
  Future<List<int>> signWithIdentity(IdentityHandle h, List<int> p) async {
    if (failSign) throw StateError('sign failed');
    return List<int>.filled(64, 9);
  }

  @override
  Future<List<int>> mintKeyPackage(IdentityHandle h) async => const [];

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
  }

  @override
  Future<void> mlsEnsureClient(String deviceId) async {}

  @override
  Future<void> mlsInitReadOnly() async {}

  @override
  Future<void> mlsWipe() async {}

  @override
  Future<List<List<int>>> mintKeyPackages({int count = 100}) async =>
      List.generate(count, (i) => List<int>.filled(64, i & 0xff));

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
    registerFallbackValue(<int>[]);
  });

  late _MockApi api;
  late _StubCrypto crypto;
  late SecureStorageInMemory storage;
  late SessionRepository sessions;
  late LoginNotifier notifier;

  setUp(() {
    api = _MockApi();
    crypto = _StubCrypto();
    storage = SecureStorageInMemory();
    sessions = SessionRepository(storage);
    notifier = LoginNotifier(
      apiClient: api,
      crypto: crypto,
      sessions: sessions,
    );
  });

  test('refreshSession returns null when no session stored', () async {
    expect(await notifier.refreshSession(), isNull);
  });

  test('refreshSession happy path returns a fresh JWT and persists it', () async {
    const stored = JwtSession(accountId: 'acc-1', deviceId: 'dev-1', jwt: 'old', username: 'acc-user');
    await sessions.save(stored);

    when(() => api.requestChallenge(
          username: any(named: 'username'),
          deviceId: any(named: 'deviceId'),
        )).thenAnswer(
      (_) async => ChallengeReply(
        challenge: const [1, 2, 3],
        expiresAt: DateTime.utc(2026, 5, 7, 12, 5),
      ),
    );
    when(() => api.submitSession(
          username: any(named: 'username'),
          deviceId: any(named: 'deviceId'),
          challenge: any(named: 'challenge'),
          signature: any(named: 'signature'),
        )).thenAnswer(
      (_) async => const JwtSession(accountId: 'acc-1', deviceId: 'dev-1', jwt: 'new', username: 'acc-user'),
    );

    final fresh = await notifier.refreshSession();
    expect(fresh?.jwt, equals('new'));

    final persisted = await sessions.current();
    expect(persisted?.jwt, equals('new'));

    // The refreshed token must be applied to the shared REST client, else
    // authed REST calls keep sending the stale JWT and 401 while the WS
    // reconnects fine.
    verify(() => api.setBearerToken('new')).called(1);
  });

  test('refreshSession sends the STORED username, never an empty one', () async {
    // Regression: refresh used to send username:'' on the belief the server
    // keys off device_id — but IssueChallenge looks the account up by
    // username first and 404s. Every session refresh failed (invisible
    // until a JWT aged past 24h), and the failure cascaded into a local
    // data wipe.
    const stored = JwtSession(accountId: 'acc-1', deviceId: 'dev-1', jwt: 'old', username: 'acc-user');
    await sessions.save(stored);

    when(() => api.requestChallenge(
          username: any(named: 'username'),
          deviceId: any(named: 'deviceId'),
        )).thenAnswer((_) async =>
        ChallengeReply(challenge: const [1, 2, 3], expiresAt: DateTime.utc(2026)));
    when(() => api.submitSession(
          username: any(named: 'username'),
          deviceId: any(named: 'deviceId'),
          challenge: any(named: 'challenge'),
          signature: any(named: 'signature'),
        )).thenAnswer(
      (_) async => const JwtSession(accountId: 'acc-1', deviceId: 'dev-1', jwt: 'new', username: 'acc-user'),
    );

    await notifier.refreshSession();

    verify(() => api.requestChallenge(username: 'acc-user', deviceId: 'dev-1'))
        .called(1);
    verify(() => api.submitSession(
          username: 'acc-user',
          deviceId: 'dev-1',
          challenge: any(named: 'challenge'),
          signature: any(named: 'signature'),
        )).called(1);
  });

  test('refreshSession propagates challenge expiry', () async {
    const stored = JwtSession(accountId: 'acc-1', deviceId: 'dev-1', jwt: 'old', username: 'acc-user');
    await sessions.save(stored);

    when(() => api.requestChallenge(
          username: any(named: 'username'),
          deviceId: any(named: 'deviceId'),
        )).thenThrow(
      const ApiError(code: 'challenge_expired', message: 'x', statusCode: 410),
    );

    expect(notifier.refreshSession(), throwsA(isA<ApiError>()));
  });

  test('refreshSession propagates crypto errors', () async {
    const stored = JwtSession(accountId: 'acc-1', deviceId: 'dev-1', jwt: 'old', username: 'acc-user');
    await sessions.save(stored);

    when(() => api.requestChallenge(
          username: any(named: 'username'),
          deviceId: any(named: 'deviceId'),
        )).thenAnswer((_) async =>
        ChallengeReply(challenge: const [1], expiresAt: DateTime.utc(2026)));

    crypto.failSign = true;
    expect(notifier.refreshSession(), throwsA(isA<StateError>()));
  });

  test('refreshSession throws when stored session has no identity on this device', () async {
    const stored = JwtSession(accountId: 'acc-1', deviceId: 'dev-1', jwt: 'old', username: 'acc-user');
    await sessions.save(stored);
    crypto.injected = null; // simulate identity wiped but session lingering

    when(() => api.requestChallenge(
          username: any(named: 'username'),
          deviceId: any(named: 'deviceId'),
        )).thenAnswer((_) async =>
        ChallengeReply(challenge: const [1], expiresAt: DateTime.utc(2026)));

    expect(notifier.refreshSession(), throwsA(isA<StateError>()));
  });

  test('signOut clears persisted session', () async {
    const stored = JwtSession(accountId: 'acc-1', deviceId: 'dev-1', jwt: 'old', username: 'acc-user');
    await sessions.save(stored);
    await notifier.signOut();
    expect(await sessions.current(), isNull);
  });

  test('refreshSession calls mlsInit after session is restored', () async {
    const stored = JwtSession(accountId: 'acc-1', deviceId: 'dev-1', jwt: 'old', username: 'acc-user');
    await sessions.save(stored);

    when(() => api.requestChallenge(
          username: any(named: 'username'),
          deviceId: any(named: 'deviceId'),
        )).thenAnswer(
      (_) async => ChallengeReply(
        challenge: const [1, 2, 3],
        expiresAt: DateTime.utc(2026, 5, 7, 12, 5),
      ),
    );
    when(() => api.submitSession(
          username: any(named: 'username'),
          deviceId: any(named: 'deviceId'),
          challenge: any(named: 'challenge'),
          signature: any(named: 'signature'),
        )).thenAnswer(
      (_) async => const JwtSession(accountId: 'acc-1', deviceId: 'dev-1', jwt: 'new', username: 'acc-user'),
    );

    await notifier.refreshSession();

    expect(crypto.mlsInitCalls, equals(1));
  });

  test('refreshSession does not call mlsInit when no session is stored', () async {
    await notifier.refreshSession();

    expect(crypto.mlsInitCalls, equals(0));
  });
}
