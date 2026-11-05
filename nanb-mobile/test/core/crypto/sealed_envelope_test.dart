import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/core/crypto/sealed_envelope.dart';

void main() {
  final codec = SealedEnvelope();
  final x = X25519();

  Future<(List<int> pub, List<int> priv)> newKeys() async {
    final kp = await x.newKeyPair();
    final pub = (await kp.extractPublicKey()).bytes;
    final priv = await kp.extractPrivateKeyBytes();
    return (pub, priv);
  }

  test('round-trips the inner payload for the recipient', () async {
    final (pub, priv) = await newKeys();
    final pt = utf8.encode('the inner MLS ciphertext bytes');
    final sealed = await codec.seal(recipientX25519PubKey: pub, plaintext: pt);
    final opened = await codec.open(recipientX25519PrivKey: priv, sealed: sealed);
    expect(opened, equals(pt));
  });

  test('a different recipient key cannot open it', () async {
    final (pub, _) = await newKeys();
    final (_, otherPriv) = await newKeys();
    final sealed =
        await codec.seal(recipientX25519PubKey: pub, plaintext: const [1, 2, 3]);
    await expectLater(
      codec.open(recipientX25519PrivKey: otherPriv, sealed: sealed),
      throwsA(isA<SecretBoxAuthenticationError>()),
    );
  });

  test('tampering the AEAD tag is detected', () async {
    final (pub, priv) = await newKeys();
    final sealed = await codec
        .seal(recipientX25519PubKey: pub, plaintext: const [9, 9, 9, 9]);
    final tampered = Uint8List.fromList(sealed);
    tampered[tampered.length - 1] ^= 0xFF;
    await expectLater(
      codec.open(recipientX25519PrivKey: priv, sealed: tampered),
      throwsA(isA<SecretBoxAuthenticationError>()),
    );
  });

  test('tampering the ciphertext body is detected', () async {
    final (pub, priv) = await newKeys();
    final sealed = await codec
        .seal(recipientX25519PubKey: pub, plaintext: const [9, 9, 9, 9, 9, 9]);
    final tampered = Uint8List.fromList(sealed);
    tampered[45] ^= 0x01; // first ciphertext byte (after 1+32+12 header)
    await expectLater(
      codec.open(recipientX25519PrivKey: priv, sealed: tampered),
      throwsA(isA<SecretBoxAuthenticationError>()),
    );
  });

  test('rejects an unknown version byte', () async {
    final (pub, priv) = await newKeys();
    final sealed =
        await codec.seal(recipientX25519PubKey: pub, plaintext: const [1]);
    final bad = Uint8List.fromList(sealed)..[0] = 0x03;
    await expectLater(
      codec.open(recipientX25519PrivKey: priv, sealed: bad),
      throwsA(isA<FormatException>()),
    );
  });

  test('seals as the padded version (0x02)', () async {
    final (pub, _) = await newKeys();
    final sealed =
        await codec.seal(recipientX25519PubKey: pub, plaintext: const [1, 2]);
    expect(sealed[0], SealedEnvelope.paddedVersion);
  });

  test('pads small plaintexts to a fixed bucket so size leaks only the bucket',
      () async {
    final (pub, _) = await newKeys();
    // A 1-byte "ok"-class message and a ~200-byte one both land in the 256
    // bucket → identical wire length. The server can't tell them apart.
    final tiny =
        await codec.seal(recipientX25519PubKey: pub, plaintext: const [7]);
    final small = await codec.seal(
        recipientX25519PubKey: pub, plaintext: List<int>.filled(200, 7));
    expect(tiny.length, small.length);
    // header(45) + bucket(256) + tag(16)
    expect(tiny.length, 45 + 256 + 16);
  });

  test('crosses to the next bucket only when the plaintext exceeds the prior',
      () async {
    final (pub, _) = await newKeys();
    // 252 + 4-byte length prefix == 256 → still the 256 bucket; 253 spills to 1024.
    final atEdge = await codec.seal(
        recipientX25519PubKey: pub, plaintext: List<int>.filled(252, 1));
    final overEdge = await codec.seal(
        recipientX25519PubKey: pub, plaintext: List<int>.filled(253, 1));
    expect(atEdge.length, 45 + 256 + 16);
    expect(overEdge.length, 45 + 1024 + 16);
  });

  test('round-trips across bucket boundaries', () async {
    final (pub, priv) = await newKeys();
    for (final n in [0, 1, 251, 252, 253, 1020, 5000, 20000, 70000]) {
      final pt = List<int>.generate(n, (i) => i & 0xFF);
      final sealed =
          await codec.seal(recipientX25519PubKey: pub, plaintext: pt);
      final opened =
          await codec.open(recipientX25519PrivKey: priv, sealed: sealed);
      expect(opened, equals(pt), reason: 'len $n');
    }
  });

  test('rounds a large plaintext up to a multiple of the top bucket', () async {
    expect(SealedEnvelope.bucketFor(65537), 65536 * 2);
    expect(SealedEnvelope.bucketFor(130000), 65536 * 2);
    expect(SealedEnvelope.bucketFor(131073), 65536 * 3);

    final (pub, priv) = await newKeys();
    final pt = List<int>.generate(70000, (i) => i & 0xFF);
    final sealed = await codec.seal(recipientX25519PubKey: pub, plaintext: pt);
    expect(sealed.length, 45 + 65536 * 2 + 16);
    final opened =
        await codec.open(recipientX25519PrivKey: priv, sealed: sealed);
    expect(opened, equals(pt));
  });

  test('still opens a legacy unpadded v1 blob', () async {
    // Forge a v1 blob (plaintext == AEAD plaintext, no length prefix) the way a
    // pre-padding sender would have, and confirm open() strips nothing.
    final (pub, priv) = await newKeys();
    final x = X25519();
    final aead = AesGcm.with256bits();
    final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
    final salt = Uint8List.fromList('nanb/sealed-sender/v1'.codeUnits);

    final eph = await x.newKeyPair();
    final ephPub = (await eph.extractPublicKey()).bytes;
    final shared = await x.sharedSecretKey(
      keyPair: eph,
      remotePublicKey: SimplePublicKey(pub, type: KeyPairType.x25519),
    );
    final key = await hkdf.deriveKey(secretKey: shared, nonce: salt, info: pub);
    final pt = utf8.encode('legacy unpadded payload');
    final box = await aead.encrypt(pt, secretKey: key);
    final legacy = (BytesBuilder(copy: false)
          ..addByte(SealedEnvelope.version) // 0x01
          ..add(ephPub)
          ..add(box.nonce)
          ..add(box.cipherText)
          ..add(box.mac.bytes))
        .toBytes();

    final opened =
        await codec.open(recipientX25519PrivKey: priv, sealed: legacy);
    expect(opened, equals(pt));
  });

  test('rejects a too-short blob', () async {
    final (_, priv) = await newKeys();
    await expectLater(
      codec.open(recipientX25519PrivKey: priv, sealed: List<int>.filled(10, 0)),
      throwsA(isA<FormatException>()),
    );
  });

  test('the same plaintext seals to different blobs (fresh ephemeral)',
      () async {
    final (pub, _) = await newKeys();
    final a =
        await codec.seal(recipientX25519PubKey: pub, plaintext: const [7, 7, 7]);
    final b =
        await codec.seal(recipientX25519PubKey: pub, plaintext: const [7, 7, 7]);
    expect(a, isNot(equals(b)));
  });

  test('empty plaintext round-trips', () async {
    final (pub, priv) = await newKeys();
    final sealed =
        await codec.seal(recipientX25519PubKey: pub, plaintext: const []);
    final opened = await codec.open(recipientX25519PrivKey: priv, sealed: sealed);
    expect(opened, isEmpty);
  });

  test('seal rejects a wrong-length recipient key', () async {
    expect(
      () => codec.seal(recipientX25519PubKey: const [1, 2, 3], plaintext: const [0]),
      throwsArgumentError,
    );
  });
}
