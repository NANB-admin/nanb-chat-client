import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/core/crypto/sealed_inner.dart';

void main() {
  test('round-trips all fields', () {
    const inner = SealedInner(
      conversationId: 'group-abc-123',
      envelopeType: 'mls_application',
      senderDeviceId: '2465ede4-1a51-4c3d-9591-6832f2a3bd1a',
      ciphertext: [1, 2, 3, 250, 0, 255, 42],
    );
    final decoded = SealedInner.decode(inner.encode());
    expect(decoded.conversationId, equals(inner.conversationId));
    expect(decoded.envelopeType, equals(inner.envelopeType));
    expect(decoded.senderDeviceId, equals(inner.senderDeviceId));
    expect(decoded.ciphertext, equals(inner.ciphertext));
  });

  test('round-trips an empty ciphertext (handshake-style)', () {
    const inner = SealedInner(
      conversationId: 'c',
      envelopeType: 'mls_handshake',
      senderDeviceId: 'd',
      ciphertext: [],
    );
    final decoded = SealedInner.decode(inner.encode());
    expect(decoded.ciphertext, isEmpty);
    expect(decoded.conversationId, equals('c'));
  });

  test('handles unicode / multi-byte conversation ids', () {
    const inner = SealedInner(
      conversationId: 'café-世界-🔒',
      envelopeType: 'text_legacy',
      senderDeviceId: 'dev',
      ciphertext: [7, 7],
    );
    final decoded = SealedInner.decode(inner.encode());
    expect(decoded.conversationId, equals('café-世界-🔒'));
    expect(utf8.encode(decoded.conversationId).length,
        greaterThan(decoded.conversationId.length),
        reason: 'sanity: the id really is multi-byte');
  });

  test('preserves a large ciphertext exactly', () {
    final big = List<int>.generate(70000, (i) => i % 256);
    final inner = SealedInner(
      conversationId: 'g',
      envelopeType: 'media_envelope',
      senderDeviceId: 'dev',
      ciphertext: big,
    );
    final decoded = SealedInner.decode(inner.encode());
    expect(decoded.ciphertext, equals(big));
  });

  test('rejects a bad version byte', () {
    final bytes = const SealedInner(
      conversationId: 'g',
      envelopeType: 't',
      senderDeviceId: 'd',
      ciphertext: [1],
    ).encode();
    bytes[0] = 0x02;
    expect(() => SealedInner.decode(bytes), throwsA(isA<FormatException>()));
  });

  test('rejects a truncated buffer', () {
    final bytes = const SealedInner(
      conversationId: 'group',
      envelopeType: 'text_legacy',
      senderDeviceId: 'dev',
      ciphertext: [1, 2, 3],
    ).encode();
    expect(() => SealedInner.decode(bytes.sublist(0, 4)),
        throwsA(isA<FormatException>()));
  });

  test('empty buffer is rejected', () {
    expect(() => SealedInner.decode(const []), throwsA(isA<FormatException>()));
  });
}
