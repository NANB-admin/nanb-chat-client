import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/core/crypto/crypto_bridge_dart.dart';
import 'package:nanb_chat/core/crypto/delivered_receipt.dart';
import 'package:nanb_chat/core/crypto/sealed_envelope.dart';
import 'package:nanb_chat/core/crypto/sealed_inner.dart';
import 'package:nanb_chat/core/models/envelope.dart';
import 'package:nanb_chat/core/network/api_client.dart';
import 'package:nanb_chat/core/push/push_kind.dart';
import 'package:nanb_chat/core/push/sealed_delivered_receipt.dart';
import 'package:nanb_chat/core/secure_storage/secure_storage.dart';

/// Records the one ApiClient method the bg sender uses; everything else throws.
class _RecordingApi implements ApiClient {
  int submits = 0;
  SubmitMessagePayload? lastPayload;
  List<int>? lastAccessKey;

  @override
  Future<SubmitMessageResult> submitSealedUnauthenticated(
      SubmitMessagePayload payload, List<int> accessKey) async {
    submits++;
    lastPayload = payload;
    lastAccessKey = accessKey;
    return SubmitMessageResult(
        envelopeId: 'receipt-env', serverTs: DateTime.utc(2026));
  }

  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnimplementedError('unexpected ApiClient call: ${i.memberName}');
}

void main() {
  final x = X25519();
  final codec = SealedEnvelope();

  group('peer seal key directory', () {
    test('write / read / remove / clear round-trip', () async {
      final s = SecureStorageInMemory();
      final x25519 = List<int>.filled(32, 7);
      final uak = [1, 2, 3, 4];
      await writePeerSealKeys(s, 'dev-A', x25519Pub: x25519, uak: uak);

      final got = await readPeerSealKeys(s, 'dev-A');
      expect(got!.x25519Pub, x25519);
      expect(got.uak, uak);
      expect(await readPeerSealKeys(s, 'dev-missing'), isNull);

      await removePeerSealKeys(s, 'dev-A');
      expect(await readPeerSealKeys(s, 'dev-A'), isNull);

      await writePeerSealKeys(s, 'dev-B', x25519Pub: x25519, uak: uak);
      await clearPeerSealKeys(s);
      expect(await readPeerSealKeys(s, 'dev-B'), isNull);
    });

    test('rejects a wrong-length x25519 or empty uak', () async {
      final s = SecureStorageInMemory();
      await writePeerSealKeys(s, 'd', x25519Pub: const [1, 2], uak: const [9]);
      await writePeerSealKeys(s, 'd',
          x25519Pub: List<int>.filled(32, 1), uak: const []);
      expect(await readPeerSealKeys(s, 'd'), isNull);
    });
  });

  group('sendSealedDeliveredReceipt', () {
    late SecureStorageInMemory recipStorage;
    late CryptoBridgeDart recipient;
    late List<int> recipientX25519Pub;
    late List<int> recipientIdentityPub;
    late SimpleKeyPair senderKp;
    late List<int> senderX25519Pub;
    late List<int> senderX25519Priv;
    const senderDeviceId = 'sender-dev-1';
    const conversationId = '1to1:acct-a:acct-b';
    final senderUak = List<int>.filled(32, 0x5A);

    setUp(() async {
      recipStorage = SecureStorageInMemory();
      recipient = CryptoBridgeDart(storage: recipStorage);
      final handle = await recipient.generateIdentity();
      recipientX25519Pub = handle.x25519PublicKey;
      recipientIdentityPub = handle.publicKey;

      senderKp = await x.newKeyPair();
      senderX25519Pub = (await senderKp.extractPublicKey()).bytes;
      senderX25519Priv = await senderKp.extractPrivateKeyBytes();
    });

    // The original sealed message the sender (sender-dev-1) deposited for us.
    Future<List<int>> originalSealedBlob() async {
      final inner = SealedInner(
        conversationId: conversationId,
        envelopeType: EnvelopeType.mlsApplication,
        senderDeviceId: senderDeviceId,
        ciphertext: const [1, 2, 3, 4],
      ).encode();
      return codec.seal(
          recipientX25519PubKey: recipientX25519Pub, plaintext: inner);
    }

    test('opens the seal, signs, and submits a sealed receipt to the sender',
        () async {
      await writePeerSealKeys(recipStorage, senderDeviceId,
          x25519Pub: senderX25519Pub, uak: senderUak);
      final api = _RecordingApi();

      final ok = await sendSealedDeliveredReceipt(
        deliveredEnvelopeId: 'env-1',
        sealedBlob: await originalSealedBlob(),
        crypto: recipient,
        storage: recipStorage,
        api: api,
      );

      expect(ok, isTrue);
      expect(api.submits, 1);
      expect(api.lastAccessKey, senderUak,
          reason: 'presents the SENDER\'s UAK on the unauth path');
      expect(api.lastPayload!.recipientDeviceId, senderDeviceId);
      expect(api.lastPayload!.envelopeType, EnvelopeType.sealed);
      expect(api.lastPayload!.conversationId, isEmpty,
          reason: 'no conversation id on the wire');

      // The submitted blob must open for the SENDER and carry a delivered
      // receipt signed by US (the recipient) over the right (conv, env).
      final innerBytes = await codec.open(
          recipientX25519PrivKey: senderX25519Priv,
          sealed: api.lastPayload!.ciphertext);
      final rec = SealedInner.decode(innerBytes);
      expect(rec.envelopeType, EnvelopeType.deliveredReceipt);
      final receipt = DeliveredReceipt.tryDecode(rec.ciphertext)!;
      expect(receipt.deliveredEnvelopeId, 'env-1');
      expect(receipt.conversationId, conversationId);
      expect(await receipt.verify(recipientIdentityPub), isTrue);
    });

    test('submits the receipt as a silent push so the sender gets no banner',
        () async {
      await writePeerSealKeys(recipStorage, senderDeviceId,
          x25519Pub: senderX25519Pub, uak: senderUak);
      final api = _RecordingApi();

      await sendSealedDeliveredReceipt(
        deliveredEnvelopeId: 'env-1',
        sealedBlob: await originalSealedBlob(),
        crypto: recipient,
        storage: recipStorage,
        api: api,
      );

      expect(api.lastPayload!.pushKind, PushKind.silent);
    });

    test('skips (no submit) when the peer keys are not mirrored yet', () async {
      final api = _RecordingApi();
      final ok = await sendSealedDeliveredReceipt(
        deliveredEnvelopeId: 'env-1',
        sealedBlob: await originalSealedBlob(),
        crypto: recipient,
        storage: recipStorage, // nothing mirrored
        api: api,
      );
      expect(ok, isFalse);
      expect(api.submits, 0);
    });

    test('returns false for an empty blob', () async {
      final api = _RecordingApi();
      final ok = await sendSealedDeliveredReceipt(
        deliveredEnvelopeId: 'env-1',
        sealedBlob: const [],
        crypto: recipient,
        storage: recipStorage,
        api: api,
      );
      expect(ok, isFalse);
      expect(api.submits, 0);
    });

    test('returns false when the blob is not openable by us', () async {
      await writePeerSealKeys(recipStorage, senderDeviceId,
          x25519Pub: senderX25519Pub, uak: senderUak);
      final api = _RecordingApi();
      // Sealed to a DIFFERENT recipient → our openSealed throws → no receipt.
      final otherKp = await x.newKeyPair();
      final otherPub = (await otherKp.extractPublicKey()).bytes;
      final notForUs = await codec.seal(
          recipientX25519PubKey: otherPub,
          plaintext: SealedInner(
            conversationId: conversationId,
            envelopeType: EnvelopeType.mlsApplication,
            senderDeviceId: senderDeviceId,
            ciphertext: const [1],
          ).encode());

      final ok = await sendSealedDeliveredReceipt(
        deliveredEnvelopeId: 'env-1',
        sealedBlob: notForUs,
        crypto: recipient,
        storage: recipStorage,
        api: api,
      );
      expect(ok, isFalse);
      expect(api.submits, 0);
    });
  });
}
