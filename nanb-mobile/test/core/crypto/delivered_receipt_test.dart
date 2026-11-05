import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/core/crypto/delivered_receipt.dart';

void main() {
  final ed = Ed25519();

  Future<(List<int> pub, List<int> sig)> sign(
      String conv, String env) async {
    final kp = await ed.newKeyPair();
    final pub = (await kp.extractPublicKey()).bytes;
    final s = await ed.sign(DeliveredReceipt.signingBytes(conv, env),
        keyPair: kp);
    return (pub, s.bytes);
  }

  test('encode/decode round-trips', () {
    const r = DeliveredReceipt(
      deliveredEnvelopeId: 'env-1',
      conversationId: '1to1:a:b',
      signature: [1, 2, 3, 4],
    );
    final back = DeliveredReceipt.tryDecode(r.encode())!;
    expect(back.deliveredEnvelopeId, 'env-1');
    expect(back.conversationId, '1to1:a:b');
    expect(back.signature, [1, 2, 3, 4]);
  });

  test('verifies a genuine signature against the signer identity', () async {
    final (pub, sig) = await sign('1to1:a:b', 'env-1');
    const r0 = DeliveredReceipt(
        deliveredEnvelopeId: 'env-1', conversationId: '1to1:a:b', signature: []);
    final r = DeliveredReceipt(
      deliveredEnvelopeId: r0.deliveredEnvelopeId,
      conversationId: r0.conversationId,
      signature: sig,
    );
    expect(await r.verify(pub), isTrue);
  });

  test('rejects a signature from a different identity', () async {
    final (_, sig) = await sign('1to1:a:b', 'env-1');
    final wrongPub =
        (await (await ed.newKeyPair()).extractPublicKey()).bytes;
    final r = DeliveredReceipt(
        deliveredEnvelopeId: 'env-1',
        conversationId: '1to1:a:b',
        signature: sig);
    expect(await r.verify(wrongPub), isFalse);
  });

  test('rejects when the signed envelope id is tampered', () async {
    final (pub, sig) = await sign('1to1:a:b', 'env-1');
    // Same signature, but claim a DIFFERENT delivered envelope id → the bound
    // signing bytes no longer match, so verification must fail.
    final tampered = DeliveredReceipt(
        deliveredEnvelopeId: 'env-OTHER',
        conversationId: '1to1:a:b',
        signature: sig);
    expect(await tampered.verify(pub), isFalse);
  });

  test('verify is false for a wrong-length public key', () async {
    final (_, sig) = await sign('1to1:a:b', 'env-1');
    final r = DeliveredReceipt(
        deliveredEnvelopeId: 'env-1',
        conversationId: '1to1:a:b',
        signature: sig);
    expect(await r.verify(const [1, 2, 3]), isFalse);
  });

  test('tryDecode returns null on garbage / missing fields', () {
    expect(DeliveredReceipt.tryDecode('not json'.codeUnits), isNull);
    expect(DeliveredReceipt.tryDecode('{}'.codeUnits), isNull);
    expect(
      DeliveredReceipt.tryDecode('{"env":"e","conv":"c"}'.codeUnits),
      isNull,
      reason: 'missing signature',
    );
  });
}
