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
import 'package:nanb_chat/features/onboarding/recovery_phrase.dart';
import 'package:nanb_chat/features/onboarding/recovery_phrase_storage.dart';
import 'package:nanb_chat/features/onboarding/restore_notifier.dart';
import 'package:nanb_chat/features/onboarding/session_repository.dart';

class _MockApi extends Mock implements ApiClient {}

class _RecordingCrypto implements CryptoBridge {
  @override
  Future<bool> consumeMlsStoreReset() async => false;

  List<int>? lastSeed;
  List<int>? lastSignedPayload;
  int mlsInitCalls = 0;

  @override
  Future<IdentityHandle> generateIdentity({List<int>? seed}) async {
    lastSeed = seed;
    return IdentityHandle(
      id: 'restored',
      publicKey: List<int>.filled(32, 9),
      x25519PublicKey: List<int>.filled(32, 13),
    );
  }

  @override
  Future<IdentityHandle?> currentIdentity() async => null;

  @override
  Future<List<int>> signWithIdentity(IdentityHandle handle, List<int> payload) async {
    lastSignedPayload = List<int>.from(payload);
    return List<int>.filled(64, 1);
  }

  @override
  Future<List<int>> mintKeyPackage(IdentityHandle handle) async => const [];

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

  String? ensuredClientDeviceId;

  @override
  Future<void> mlsEnsureClient(String deviceId) async {
    ensuredClientDeviceId = deviceId;
  }

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

const _validPhrase =
    'abandon abandon abandon abandon abandon abandon abandon abandon '
    'abandon abandon abandon abandon abandon abandon abandon abandon '
    'abandon abandon abandon abandon abandon abandon abandon art';

void main() {
  late _MockApi api;
  late _RecordingCrypto crypto;
  late SecureStorageInMemory storage;
  late SessionRepository sessions;
  late RestoreNotifier notifier;

  setUpAll(() {
    registerFallbackValue(<List<int>>[]);
  });

  setUp(() {
    api = _MockApi();
    crypto = _RecordingCrypto();
    storage = SecureStorageInMemory();
    sessions = SessionRepository(storage);
    notifier = RestoreNotifier(
      apiClient: api,
      crypto: crypto,
      sessions: sessions,
      phraseStorage: RecoveryPhraseStorage(storage),
    );
  });

  test('rejects too-short phrase before any network call', () async {
    expect(
      () => notifier.restoreFromPhrase(username: 'nass', phrase: 'this is garbage'),
      throwsA(isA<InvalidRecoveryPhraseException>()),
    );
    verifyNever(() => api.requestRestoreChallenge(username: any(named: 'username')));
  });

  test('accepts a non-BIP-39 custom phrase of >= 8 words', () async {
    final challenge = List<int>.generate(32, (i) => i);
    when(() => api.requestRestoreChallenge(username: 'nass')).thenAnswer((_) async => ChallengeReply(
          challenge: challenge,
          expiresAt: DateTime.utc(2026, 5, 8, 13),
        ));
    const session = JwtSession(accountId: 'acc-9', deviceId: 'dev-9', jwt: 'jwt-9', username: 'nass');
    when(() => api.submitRestoreSession(
          username: any(named: 'username'),
          identityPubKey: any(named: 'identityPubKey'),
          challenge: any(named: 'challenge'),
          signature: any(named: 'signature'),
          devicePubKey: any(named: 'devicePubKey'),
          x25519PubKey: any(named: 'x25519PubKey'),
        )).thenAnswer((_) async => session);

    // Casing/whitespace differences normalize to the same seed.
    const typed = '  My EIGHT word custom\nphrase about green TURTLES ';
    const normalized = 'my eight word custom phrase about green turtles';
    final got = await notifier.restoreFromPhrase(username: 'nass', phrase: typed);

    expect(got, equals(session));
    expect(crypto.lastSeed, equals(RecoveryPhrase.toSeed(normalized)));
    expect(await RecoveryPhraseStorage(storage).read(), equals(normalized));
  });

  test('happy path: derives seed, signs challenge, persists session', () async {
    final challenge = List<int>.generate(32, (i) => i);
    when(() => api.requestRestoreChallenge(username: 'nass')).thenAnswer((_) async => ChallengeReply(
          challenge: challenge,
          expiresAt: DateTime.utc(2026, 5, 8, 13),
        ));
    const session = JwtSession(accountId: 'acc-9', deviceId: 'dev-9', jwt: 'jwt-9', username: 'nass');
    when(() => api.submitRestoreSession(
          username: any(named: 'username'),
          identityPubKey: any(named: 'identityPubKey'),
          challenge: any(named: 'challenge'),
          signature: any(named: 'signature'),
          devicePubKey: any(named: 'devicePubKey'),
          x25519PubKey: any(named: 'x25519PubKey'),
        )).thenAnswer((_) async => session);

    final got = await notifier.restoreFromPhrase(username: 'nass', phrase: _validPhrase);

    expect(got, equals(session));
    expect(crypto.lastSeed, equals(RecoveryPhrase.toSeed(_validPhrase)));
    expect(crypto.lastSignedPayload, equals(challenge));
    expect(await sessions.current(), equals(session));
    // Phrase persisted so settings reveal can show it.
    expect(await RecoveryPhraseStorage(storage).read(), equals(_validPhrase));
  });

  test('republishes a fresh key-package batch after restore', () async {
    final challenge = List<int>.generate(32, (i) => i);
    when(() => api.requestRestoreChallenge(username: 'nass')).thenAnswer((_) async => ChallengeReply(
          challenge: challenge,
          expiresAt: DateTime.utc(2026, 5, 8, 13),
        ));
    const session = JwtSession(accountId: 'acc-9', deviceId: 'dev-9', jwt: 'jwt-9', username: 'nass');
    when(() => api.submitRestoreSession(
          username: any(named: 'username'),
          identityPubKey: any(named: 'identityPubKey'),
          challenge: any(named: 'challenge'),
          signature: any(named: 'signature'),
          devicePubKey: any(named: 'devicePubKey'),
          x25519PubKey: any(named: 'x25519PubKey'),
        )).thenAnswer((_) async => session);
    List<List<int>>? published;
    when(() => api.publishKeyPackages(any())).thenAnswer((inv) async {
      published = inv.positionalArguments.first as List<List<int>>;
      return published!.length;
    });

    await notifier.restoreFromPhrase(username: 'nass', phrase: _validPhrase);

    // The restored device wiped its CoreCrypto store, so the server purged its
    // old (dead) key packages — the client must re-arm the bearer + republish
    // a fresh batch so peers fetch packages it can actually decrypt.
    verify(() => api.setBearerToken('jwt-9')).called(1);
    expect(crypto.ensuredClientDeviceId, equals('dev-9'));
    expect(published, isNotNull);
    expect(published!.length, equals(100));
  });

  test('propagates ApiError when account is not found', () async {
    when(() => api.requestRestoreChallenge(username: any(named: 'username'))).thenThrow(
      const ApiError(code: 'account_not_found', message: 'no', statusCode: 404),
    );

    expect(
      () => notifier.restoreFromPhrase(username: 'ghost', phrase: _validPhrase),
      throwsA(isA<ApiError>().having((e) => e.code, 'code', 'account_not_found')),
    );
  });

  test('propagates ApiError when signature is rejected by the server', () async {
    when(() => api.requestRestoreChallenge(username: 'nass')).thenAnswer((_) async => ChallengeReply(
          challenge: List<int>.filled(32, 0),
          expiresAt: DateTime.utc(2026, 5, 8, 13),
        ));
    when(() => api.submitRestoreSession(
          username: any(named: 'username'),
          identityPubKey: any(named: 'identityPubKey'),
          challenge: any(named: 'challenge'),
          signature: any(named: 'signature'),
          devicePubKey: any(named: 'devicePubKey'),
          x25519PubKey: any(named: 'x25519PubKey'),
        )).thenThrow(
      const ApiError(code: 'bad_signature', message: 'no', statusCode: 401),
    );

    expect(
      () => notifier.restoreFromPhrase(username: 'nass', phrase: _validPhrase),
      throwsA(isA<ApiError>().having((e) => e.code, 'code', 'bad_signature')),
    );
    // Session is NOT persisted on submit failure.
    expect(await sessions.current(), isNull);
  });

  test('does not save session if challenge call fails', () async {
    when(() => api.requestRestoreChallenge(username: any(named: 'username'))).thenThrow(
      const ApiError(code: 'challenge_expired', message: 'x', statusCode: 410),
    );

    expect(
      () => notifier.restoreFromPhrase(username: 'nass', phrase: _validPhrase),
      throwsA(isA<ApiError>().having((e) => e.code, 'code', 'challenge_expired')),
    );
    expect(await sessions.current(), isNull);
  });

  test('restoreFromPhrase calls mlsInit after generateIdentity succeeds', () async {
    final challenge = List<int>.generate(32, (i) => i);
    when(() => api.requestRestoreChallenge(username: 'nass')).thenAnswer((_) async => ChallengeReply(
          challenge: challenge,
          expiresAt: DateTime.utc(2026, 5, 8, 13),
        ));
    when(() => api.submitRestoreSession(
          username: any(named: 'username'),
          identityPubKey: any(named: 'identityPubKey'),
          challenge: any(named: 'challenge'),
          signature: any(named: 'signature'),
          devicePubKey: any(named: 'devicePubKey'),
          x25519PubKey: any(named: 'x25519PubKey'),
        )).thenAnswer((_) async => const JwtSession(accountId: 'acc-9', deviceId: 'dev-9', jwt: 'jwt-9', username: 'nass'));

    await notifier.restoreFromPhrase(username: 'nass', phrase: _validPhrase);

    // Twice: once before the restore call, then again inside the post-restore
    // MLS block, which re-runs the (idempotent) open as the retry for a store
    // that failed to open the first time.
    expect(crypto.mlsInitCalls, equals(2));
  });

  test('restoreFromPhrase initializes the MLS client with the restored device id', () async {
    final challenge = List<int>.generate(32, (i) => i);
    when(() => api.requestRestoreChallenge(username: 'nass')).thenAnswer((_) async => ChallengeReply(
          challenge: challenge,
          expiresAt: DateTime.utc(2026, 5, 8, 13),
        ));
    when(() => api.submitRestoreSession(
          username: any(named: 'username'),
          identityPubKey: any(named: 'identityPubKey'),
          challenge: any(named: 'challenge'),
          signature: any(named: 'signature'),
          devicePubKey: any(named: 'devicePubKey'),
          x25519PubKey: any(named: 'x25519PubKey'),
        )).thenAnswer((_) async => const JwtSession(accountId: 'acc-9', deviceId: 'dev-9', jwt: 'jwt-9', username: 'nass'));

    await notifier.restoreFromPhrase(username: 'nass', phrase: _validPhrase);

    expect(crypto.ensuredClientDeviceId, equals('dev-9'));
  });
}
