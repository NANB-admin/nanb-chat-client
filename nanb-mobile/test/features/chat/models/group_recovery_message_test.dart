import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/features/chat/models/group_recovery_message.dart';

Future<(GroupRecoveryMessage, List<int>)> _signed({
  GroupRecoveryKind signedKind = GroupRecoveryKind.rejoin,
  String signedGroup = 'group:g',
  String signedDevice = 'dev',
}) async {
  final kp = await Ed25519().newKeyPair();
  final sig = await Ed25519().sign(
    GroupRecoveryMessage.signingBytes(
        kind: signedKind,
        groupId: signedGroup,
        deviceId: signedDevice,
        sinceMs: 5,
        issuedAtMs: 9),
    keyPair: kp,
  );
  return (
    GroupRecoveryMessage(
      kind: GroupRecoveryKind.rejoin,
      groupId: 'group:g',
      deviceId: 'dev',
      sinceMs: 5,
      issuedAtMs: 9,
      signature: sig.bytes,
    ),
    (await kp.extractPublicKey()).bytes,
  );
}

void main() {
  group('GroupRecoveryMessage', () {
    test('survives an encode and decode', () async {
      final (m, _) = await _signed();

      final decoded = GroupRecoveryMessage.tryDecode(m.encode())!;

      expect(decoded.groupId, 'group:g');
      expect(decoded.deviceId, 'dev');
      expect(decoded.sinceMs, 5);
      expect(decoded.issuedAtMs, 9);
      expect(decoded.kind, GroupRecoveryKind.rejoin);
      expect(decoded.signature, m.signature);
    });

    test('rejects bytes that are not JSON', () {
      expect(GroupRecoveryMessage.tryDecode([1, 2, 3]), isNull);
    });

    test('rejects an unknown kind', () {
      const body = '{"k":"other","g":"g","d":"d","s":1,"t":1,"sig":"AA=="}';

      expect(GroupRecoveryMessage.tryDecode(body.codeUnits), isNull);
    });

    test('verifies a signature from the right key', () async {
      final (m, key) = await _signed();

      expect(await m.verify(key), isTrue);
    });

    test('rejects a signature from another key', () async {
      final (m, _) = await _signed();
      final other = await (await Ed25519().newKeyPair()).extractPublicKey();

      expect(await m.verify(other.bytes), isFalse);
    });

    test('rejects a signature made for another group', () async {
      final (m, key) = await _signed(signedGroup: 'group:other');

      expect(await m.verify(key), isFalse);
    });

    test('rejects a signature made for another device', () async {
      final (m, key) = await _signed(signedDevice: 'other');

      expect(await m.verify(key), isFalse);
    });

    test('rejects a signature made for another kind', () async {
      final (m, key) = await _signed(signedKind: GroupRecoveryKind.resync);

      expect(await m.verify(key), isFalse);
    });

    test('rejects a key of the wrong length', () async {
      final (m, _) = await _signed();

      expect(await m.verify(const [1, 2, 3]), isFalse);
    });
  });
}
