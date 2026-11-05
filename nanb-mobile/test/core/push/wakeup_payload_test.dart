import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/core/push/wakeup_payload.dart';

void main() {
  group('WakeupPayload', () {
    test('tryParse returns instance for valid data', () {
      final p = WakeupPayload.tryParse({
        'envelope_id': 'env-1',
        'conversation_id': 'group:abc',
      });
      expect(p, isNotNull);
      expect(p!.envelopeId, 'env-1');
      expect(p.conversationId, 'group:abc');
    });

    test('tryParse returns null when envelope_id missing', () {
      expect(
        WakeupPayload.tryParse({'conversation_id': 'group:abc'}),
        isNull,
      );
    });

    test('tryParse returns null when conversation_id missing', () {
      expect(
        WakeupPayload.tryParse({'envelope_id': 'env-1'}),
        isNull,
      );
    });

    test('tryParse returns null on empty map', () {
      expect(WakeupPayload.tryParse(const {}), isNull);
    });

    test('equality compares both fields', () {
      const a = WakeupPayload(envelopeId: 'e', conversationId: 'c');
      const b = WakeupPayload(envelopeId: 'e', conversationId: 'c');
      const c = WakeupPayload(envelopeId: 'e2', conversationId: 'c');
      expect(a, b);
      expect(a, isNot(c));
    });

    test('decodes the inlined sealed_payload (base64) when present', () {
      // base64 of [1,2,3,4] = "AQIDBA=="
      final p = WakeupPayload.tryParse({
        'envelope_id': 'env-1',
        'conversation_id': '00000000-0000-0000-0000-000000000000',
        'sealed_payload': 'AQIDBA==',
      });
      expect(p!.sealedPayload, [1, 2, 3, 4]);
    });

    test('sealedPayload is empty when absent or malformed', () {
      final absent = WakeupPayload.tryParse(
          {'envelope_id': 'e', 'conversation_id': 'c'});
      expect(absent!.sealedPayload, isEmpty);

      final bad = WakeupPayload.tryParse({
        'envelope_id': 'e',
        'conversation_id': 'c',
        'sealed_payload': 'not%%%base64',
      });
      expect(bad!.sealedPayload, isEmpty);
    });
  });
}
