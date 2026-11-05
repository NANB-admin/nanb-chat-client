import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/core/models/account.dart';
import 'package:nanb_chat/core/models/envelope.dart';
import 'package:nanb_chat/core/models/json_bytes.dart';

void main() {
  group('bytesFromJson', () {
    test('decodes a base64 string (the Go server wire format)', () {
      // Go's encoding/json emits []byte as standard padded base64.
      final encoded = base64.encode([1, 2, 3, 250]);
      expect(bytesFromJson(encoded), [1, 2, 3, 250]);
    });

    test('accepts a JSON integer array (toJson round-trips / fixtures)', () {
      expect(bytesFromJson([10, 20, 30]), [10, 20, 30]);
    });

    test('null and empty string decode to an empty list', () {
      expect(bytesFromJson(null), isEmpty);
      expect(bytesFromJson(''), isEmpty);
    });

    test('throws on an unsupported type', () {
      expect(() => bytesFromJson(42), throwsFormatException);
    });
  });

  group('models parse the server base64 wire format', () {
    test('Account.fromJson with base64 byte fields', () {
      final acc = Account.fromJson({
        'account_id': 'a1',
        'username': 'nasser',
        'identity_pub_key': base64.encode([1, 2, 3]),
        'x25519_pub_key': base64.encode([4, 5, 6]),
      });
      expect(acc.identityPubKey, [1, 2, 3]);
      expect(acc.x25519PubKey, [4, 5, 6]);
    });

    test('Account.fromJson tolerates a missing x25519 key (legacy)', () {
      final acc = Account.fromJson({
        'account_id': 'a1',
        'username': 'nasser',
        'identity_pub_key': base64.encode([1, 2, 3]),
      });
      expect(acc.x25519PubKey, isEmpty);
    });

    test('Envelope.fromJson decodes base64 ciphertext', () {
      final env = Envelope.fromJson({
        'envelope_id': 'e1',
        'version': '1',
        'domain': 'd',
        'envelope_type': EnvelopeType.mlsApplication,
        'conversation_id': 'c1',
        'sender_device_id': 'dev1',
        'recipient_account_id': 'a2',
        'recipient_device_id': 'dev2',
        'ciphertext': base64.encode([9, 8, 7]),
        'server_ts': '2026-06-03T00:00:00Z',
      });
      expect(env.ciphertext, [9, 8, 7]);
    });

    test('Envelope toJson/fromJson round-trips (array form still works)', () {
      final env = Envelope(
        envelopeId: 'e1',
        version: '1',
        domain: 'd',
        envelopeType: EnvelopeType.mlsApplication,
        conversationId: 'c1',
        senderDeviceId: 'dev1',
        recipientAccountId: 'a2',
        recipientDeviceId: 'dev2',
        ciphertext: const [9, 8, 7],
        serverTs: DateTime.utc(2026, 6, 3),
      );
      // toJson() emits ciphertext as an int array; fromJson must still accept it.
      expect(Envelope.fromJson(env.toJson()), env);
    });
  });
}
