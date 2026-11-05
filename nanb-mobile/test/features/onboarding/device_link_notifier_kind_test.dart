import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:nanb_chat/core/crypto/crypto_bridge.dart';
import 'package:nanb_chat/core/models/device_kind.dart';
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
  });

  late _MockApi api;
  late _MockCrypto crypto;
  late DeviceLinkNotifier notifier;

  final identity = IdentityHandle(
    id: 'h',
    publicKey: List<int>.filled(32, 7),
    x25519PublicKey: List<int>.filled(32, 9),
  );

  setUp(() {
    api = _MockApi();
    crypto = _MockCrypto();
    notifier = DeviceLinkNotifier(
        apiClient: api,
        crypto: crypto,
        sessions: SessionRepository(SecureStorageInMemory()));
    when(() => crypto.currentIdentity()).thenAnswer((_) async => identity);
    when(() => crypto.signWithIdentity(identity, any()))
        .thenAnswer((_) async => List<int>.filled(64, 3));
    when(() => api.linkDevice(any())).thenAnswer(
        (_) async => LinkDeviceResult(deviceId: 'd2', linkedAt: 'now'));
  });

  Future<LinkDevicePayload> authorizeWith(DeviceKind kind) async {
    await notifier.authorize(DeviceLinkPayload(
      handleId: 'h',
      publicKey: List<int>.filled(32, 1),
      kind: kind,
    ));
    return verify(() => api.linkDevice(captureAny())).captured.single
        as LinkDevicePayload;
  }

  test('a web QR is linked with kind=web on the wire', () async {
    final sent = await authorizeWith(DeviceKind.web);
    expect(sent.toJson()['kind'], 'web');
  });

  test('a phone QR omits kind from the request', () async {
    final sent = await authorizeWith(DeviceKind.phone);
    expect(sent.toJson().containsKey('kind'), isFalse);
  });

  test('prepareNewDevice on mobile emits a QR without kind', () async {
    final prep = await notifier.prepareNewDevice();
    expect(Uri.parse(prep.qr).queryParameters.containsKey('kind'), isFalse);
  });
}
