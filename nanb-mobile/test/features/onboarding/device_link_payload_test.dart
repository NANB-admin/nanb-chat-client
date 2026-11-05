import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/features/onboarding/device_link_payload.dart';

void main() {
  // 32-byte hex pubkey (64 hex chars).
  const validPk =
      '00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff';

  // A different 32-byte hex key for the X25519 (xk) param.
  const validXk =
      'ffeeddccbbaa99887766554433221100ffeeddccbbaa99887766554433221100';

  group('DeviceLinkPayload.parse', () {
    test('parses a well-formed nanb-link URI', () {
      final p = DeviceLinkPayload.parse('nanb-link://device?id=identity-42&pk=$validPk');
      expect(p.handleId, equals('identity-42'));
      expect(p.publicKey.length, equals(32));
      expect(p.publicKey.first, equals(0x00));
      expect(p.publicKey.last, equals(0xFF));
      // xk is optional — absent means an empty X25519 (older producer).
      expect(p.x25519PublicKey, isEmpty);
    });

    test('parses the optional xk (X25519) param', () {
      final p = DeviceLinkPayload.parse(
          'nanb-link://device?id=identity-42&pk=$validPk&xk=$validXk');
      expect(p.x25519PublicKey.length, equals(32));
      expect(p.x25519PublicKey.first, equals(0xFF));
      expect(p.x25519PublicKey.last, equals(0x00));
    });

    test('rejects a malformed xk length', () {
      expect(
        () => DeviceLinkPayload.parse(
            'nanb-link://device?id=x&pk=$validPk&xk=00112233'),
        throwsA(isA<FormatException>()),
      );
    });

    test('buildUri round-trips through parse', () {
      final uri = DeviceLinkPayload.buildUri(
        handleId: 'identity-7',
        publicKey: List<int>.filled(32, 0xAB),
        x25519PublicKey: List<int>.filled(32, 0xCD),
      );
      final p = DeviceLinkPayload.parse(uri);
      expect(p.handleId, equals('identity-7'));
      expect(p.publicKey, equals(List<int>.filled(32, 0xAB)));
      expect(p.x25519PublicKey, equals(List<int>.filled(32, 0xCD)));
    });

    test('rejects the wrong scheme', () {
      expect(
        () => DeviceLinkPayload.parse('https://device?id=x&pk=$validPk'),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects the wrong host', () {
      expect(
        () => DeviceLinkPayload.parse('nanb-link://account?id=x&pk=$validPk'),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects missing id', () {
      expect(
        () => DeviceLinkPayload.parse('nanb-link://device?pk=$validPk'),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects empty id', () {
      expect(
        () => DeviceLinkPayload.parse('nanb-link://device?id=&pk=$validPk'),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects missing pk', () {
      expect(
        () => DeviceLinkPayload.parse('nanb-link://device?id=identity-1'),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects empty pk', () {
      expect(
        () => DeviceLinkPayload.parse('nanb-link://device?id=identity-1&pk='),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects odd-length pk hex', () {
      expect(
        () => DeviceLinkPayload.parse('nanb-link://device?id=x&pk=abc'),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects non-hex pk', () {
      // 64 chars, but contains "zz" which is non-hex.
      const bad = 'zz112233445566778899aabbccddeeff00112233445566778899aabbccddeeff';
      expect(
        () => DeviceLinkPayload.parse('nanb-link://device?id=x&pk=$bad'),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects pk shorter than 32 bytes', () {
      const shortPk = '00112233'; // 4 bytes
      expect(
        () => DeviceLinkPayload.parse('nanb-link://device?id=x&pk=$shortPk'),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects pk longer than 32 bytes', () {
      const longPk = '${validPk}00112233';
      expect(
        () => DeviceLinkPayload.parse('nanb-link://device?id=x&pk=$longPk'),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('DeviceLinkPayload.fingerprint', () {
    test('formats the first 12 hex chars in 4-char groups, uppercase', () {
      final p = DeviceLinkPayload.parse('nanb-link://device?id=x&pk=$validPk');
      expect(p.fingerprint, equals('0011 2233 4455'));
    });
  });
}
