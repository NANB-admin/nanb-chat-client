import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:nanb_chat/core/crypto/crypto_bridge.dart';
import 'package:nanb_chat/core/models/jwt_session.dart';
import 'package:nanb_chat/core/network/api_client.dart';
import 'package:nanb_chat/core/secure_storage/secure_storage.dart';
import 'package:nanb_chat/features/onboarding/device_link_notifier.dart';
import 'package:nanb_chat/features/onboarding/device_link_payload.dart';
import 'package:nanb_chat/features/onboarding/session_repository.dart';

class _MockApi extends Mock implements ApiClient {}

class _MockCrypto extends Mock implements CryptoBridge {}

class _FakeLinkPayload extends Fake implements LinkDevicePayload {}

void main() {
  setUpAll(() {
    registerFallbackValue(_FakeLinkPayload());
    registerFallbackValue(<int>[]);
    registerFallbackValue(<List<int>>[]);
  });

  late _MockApi api;
  late _MockCrypto crypto;
  late SessionRepository sessions;
  late DeviceLinkNotifier notifier;

  final identity = IdentityHandle(
    id: 'dev-handle',
    publicKey: List<int>.filled(32, 7),
    x25519PublicKey: List<int>.filled(32, 9),
  );

  setUp(() {
    api = _MockApi();
    crypto = _MockCrypto();
    sessions = SessionRepository(SecureStorageInMemory());
    notifier =
        DeviceLinkNotifier(apiClient: api, crypto: crypto, sessions: sessions);
  });

  group('authorize (primary device)', () {
    test('signs the SCANNED device pubkey with the account identity + links',
        () async {
      when(() => crypto.currentIdentity()).thenAnswer((_) async => identity);
      when(() => crypto.signWithIdentity(identity, any()))
          .thenAnswer((_) async => List<int>.filled(64, 3));
      when(() => api.linkDevice(any())).thenAnswer(
          (_) async => LinkDeviceResult(deviceId: 'dev-2', linkedAt: 'now'));

      final payload = DeviceLinkPayload(
        handleId: 'h',
        publicKey: List<int>.filled(32, 42),
        x25519PublicKey: List<int>.filled(32, 43),
      );
      final res = await notifier.authorize(payload, displayName: 'ipad');

      expect(res.deviceId, 'dev-2');
      verify(() => crypto.signWithIdentity(identity, payload.publicKey))
          .called(1);
      final sent = verify(() => api.linkDevice(captureAny())).captured.single
          as LinkDevicePayload;
      expect(sent.devicePubKey, payload.publicKey);
      expect(sent.x25519PubKey, payload.x25519PublicKey);
      expect(sent.signedLink, List<int>.filled(64, 3));
      expect(sent.deviceDisplayName, 'ipad');
      // The new device publishes its own key packages once online.
      expect(sent.keyPackages, isEmpty);
    });

    test('throws when there is no local identity to authorize with', () async {
      when(() => crypto.currentIdentity()).thenAnswer((_) async => null);
      expect(
        () => notifier.authorize(
            DeviceLinkPayload(handleId: 'h', publicKey: List<int>.filled(32, 1))),
        throwsStateError,
      );
    });
  });

  group('prepareNewDevice (new device)', () {
    test('mints a fresh identity when none exists and builds a QR with xk',
        () async {
      when(() => crypto.currentIdentity()).thenAnswer((_) async => null);
      when(() => crypto.generateIdentity(seed: any(named: 'seed')))
          .thenAnswer((_) async => identity);

      final prep = await notifier.prepareNewDevice();

      final parsed = DeviceLinkPayload.parse(prep.qr);
      expect(parsed.publicKey, identity.publicKey);
      expect(parsed.x25519PublicKey, identity.x25519PublicKey);
      expect(parsed.handleId, identity.id);
      expect(
        prep.pubKeyHex,
        identity.publicKey.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
      );
      verify(() => crypto.generateIdentity()).called(1);
    });

    test('reuses an already-present local identity (stable QR across resumes)',
        () async {
      when(() => crypto.currentIdentity()).thenAnswer((_) async => identity);

      final prep = await notifier.prepareNewDevice();

      verifyNever(() => crypto.generateIdentity(seed: any(named: 'seed')));
      expect(DeviceLinkPayload.parse(prep.qr).publicKey, identity.publicKey);
    });
  });

  group('completeClaim (new device)', () {
    test('runs challenge/response and saves a fully populated session',
        () async {
      when(() => crypto.currentIdentity()).thenAnswer((_) async => identity);
      when(() => crypto.mlsInit()).thenAnswer((_) async {});
      when(() => api.requestChallenge(
            username: any(named: 'username'),
            deviceId: any(named: 'deviceId'),
          )).thenAnswer((_) async =>
          ChallengeReply(challenge: const [1, 2, 3], expiresAt: DateTime.utc(2030)));
      when(() => crypto.signWithIdentity(identity, any()))
          .thenAnswer((_) async => List<int>.filled(64, 5));
      when(() => api.submitSession(
            username: any(named: 'username'),
            deviceId: any(named: 'deviceId'),
            challenge: any(named: 'challenge'),
            signature: any(named: 'signature'),
          )).thenAnswer((_) async => const JwtSession(
            accountId: '',
            deviceId: 'dev-2',
            jwt: 'JWT',
            username: 'nass',
          ));
      when(() => crypto.mlsEnsureClient(any())).thenAnswer((_) async {});
      when(() => crypto.mintKeyPackages(count: any(named: 'count')))
          .thenAnswer((_) async => [
                <int>[1]
              ]);
      when(() => api.setBearerToken(any())).thenReturn(null);
      when(() => api.publishKeyPackages(any())).thenAnswer((_) async => 1);

      final session = await notifier.completeClaim(const PendingDevice(
        linked: true,
        accountId: 'acc-1',
        deviceId: 'dev-2',
        username: 'nass',
      ));

      // accountId/username come from the pending lookup, jwt from the session.
      expect(session.accountId, 'acc-1');
      expect(session.deviceId, 'dev-2');
      expect(session.jwt, 'JWT');
      expect(session.username, 'nass');
      // Persisted.
      expect((await sessions.current())!.accountId, 'acc-1');
      // Signed the server's challenge with this device's own key.
      verify(() => crypto.signWithIdentity(identity, const [1, 2, 3])).called(1);
    });

    test('throws IncompleteLinkException when the pending record is not linked',
        () async {
      expect(
        () => notifier.completeClaim(const PendingDevice(linked: false)),
        throwsA(isA<IncompleteLinkException>()),
      );
    });

    test('throws IncompleteLinkException when identity fields are missing',
        () async {
      expect(
        () => notifier.completeClaim(
            const PendingDevice(linked: true, deviceId: 'dev-2')),
        throwsA(isA<IncompleteLinkException>()),
      );
    });
  });
}
