import 'dart:convert';

import '../crypto/crypto_bridge.dart';
import '../crypto/delivered_receipt.dart';
import '../crypto/sealed_envelope.dart';
import '../crypto/sealed_inner.dart';
import '../models/envelope.dart';
import '../network/api_client.dart';
import 'push_kind.dart';
import '../secure_storage/secure_storage.dart';

/// SecureStorage key under which the FOREGROUND mirrors, per peer DEVICE, the
/// keys the background isolate needs to send a sealed "delivered" receipt back
/// to that device: a JSON object
/// `{ "<deviceId>": {"x": "<x25519 pub b64>", "u": "<peer account UAK b64>"} }`.
///
/// Only PUBLIC material + the UAK is mirrored — never a private key. The x25519
/// pub is public; the UAK is a shared, rotatable, low-value secret (it only
/// authorizes rate-limited anonymous sends to that peer). Scoped to active
/// peers and cleared on sign-out (see ConversationsNotifier).
const String kPeerSealKeysStorageKey = 'delivery.peer_seal_keys';

/// One peer device's mirrored sealing material.
class PeerSealKeys {
  const PeerSealKeys({required this.x25519Pub, required this.uak});
  final List<int> x25519Pub;
  final List<int> uak;
}

Map<String, dynamic> _decodeDirectory(String? raw) {
  if (raw == null || raw.isEmpty) return <String, dynamic>{};
  try {
    final parsed = jsonDecode(raw);
    if (parsed is Map) return Map<String, dynamic>.from(parsed);
  } catch (_) {/* corrupt → start fresh */}
  return <String, dynamic>{};
}

/// Mirrors [deviceId]'s sealing keys for the background isolate. Read-modify-
/// write of the single directory blob; a no-op when the entry is unchanged so
/// repeated receives don't thrash SecureStorage.
Future<void> writePeerSealKeys(
  SecureStorage storage,
  String deviceId, {
  required List<int> x25519Pub,
  required List<int> uak,
}) async {
  if (deviceId.isEmpty || x25519Pub.length != 32 || uak.isEmpty) return;
  final dir = _decodeDirectory(await storage.getString(kPeerSealKeysStorageKey));
  final x = base64.encode(x25519Pub);
  final u = base64.encode(uak);
  final existing = dir[deviceId];
  if (existing is Map && existing['x'] == x && existing['u'] == u) return;
  dir[deviceId] = {'x': x, 'u': u};
  await storage.putString(kPeerSealKeysStorageKey, jsonEncode(dir));
}

/// Drops one peer device's mirrored keys (e.g. on conversation delete/block).
Future<void> removePeerSealKeys(SecureStorage storage, String deviceId) async {
  final dir = _decodeDirectory(await storage.getString(kPeerSealKeysStorageKey));
  if (dir.remove(deviceId) == null) return;
  await storage.putString(kPeerSealKeysStorageKey, jsonEncode(dir));
}

/// Wipes the whole directory (sign-out / local wipe).
Future<void> clearPeerSealKeys(SecureStorage storage) =>
    storage.delete(kPeerSealKeysStorageKey);

/// Reads one peer device's mirrored keys, or null if not mirrored / malformed.
Future<PeerSealKeys?> readPeerSealKeys(
    SecureStorage storage, String deviceId) async {
  final dir = _decodeDirectory(await storage.getString(kPeerSealKeysStorageKey));
  final entry = dir[deviceId];
  if (entry is! Map) return null;
  final x = entry['x'];
  final u = entry['u'];
  if (x is! String || u is! String) return null;
  try {
    final xb = base64.decode(x);
    final ub = base64.decode(u);
    if (xb.length != 32 || ub.isEmpty) return null;
    return PeerSealKeys(x25519Pub: xb, uak: ub);
  } catch (_) {
    return null;
  }
}

/// Builds and sends a sealed, Ed25519-signed "delivered" receipt back to the
/// sender of a sealed message that arrived while the app was closed — keeping
/// the server blind (sealed sender). Driven by the FCM background isolate from
/// the inlined push blob; does NO authenticated network (only an anonymous
/// unauthenticated submit), so it never ties this device's IP to its identity.
///
/// Crucially it opens ONLY the OUTER seal — a static X25519 unwrap that does
/// NOT advance the forward-secret ratchet — so the foreground can still decrypt
/// the message later. Best-effort: returns false (silently) on any missing
/// precondition (not openable, keys not mirrored yet, no identity, submit
/// failed); the end-to-end receipt on next foreground is the durable backstop.
Future<bool> sendSealedDeliveredReceipt({
  required String deliveredEnvelopeId,
  required List<int> sealedBlob,
  required CryptoBridge crypto,
  required SecureStorage storage,
  required ApiClient api,
  SealedEnvelope? sealer,
}) async {
  if (sealedBlob.isEmpty || crypto is! SealOpener) return false;

  // 1. Open the OUTER seal (no ratchet advance) → inner record → who + where.
  final SealedInner inner;
  try {
    final innerBytes = await (crypto as SealOpener).openSealed(sealedBlob);
    inner = SealedInner.decode(innerBytes);
  } catch (_) {
    return false; // not addressed to us / corrupt — nothing to acknowledge.
  }
  final senderDeviceId = inner.senderDeviceId;
  final conversationId = inner.conversationId;
  if (senderDeviceId.isEmpty || conversationId.isEmpty) return false;

  // 2. The keys to reach the sender, mirrored by the foreground. Absent (we've
  //    never been online with this peer since linking) → skip; the e2e receipt
  //    remains the backstop.
  final keys = await readPeerSealKeys(storage, senderDeviceId);
  if (keys == null) return false;

  // 3. Sign the ack with our identity key (pure Dart; touches no ratchet).
  final identity = await crypto.currentIdentity();
  if (identity == null) return false;
  final List<int> sig;
  try {
    sig = await crypto.signWithIdentity(identity,
        DeliveredReceipt.signingBytes(conversationId, deliveredEnvelopeId));
  } catch (_) {
    return false;
  }
  final receipt = DeliveredReceipt(
    deliveredEnvelopeId: deliveredEnvelopeId,
    conversationId: conversationId,
    signature: sig,
  );

  // 4. Wrap as a sealed inner record + seal it to the sender device's x25519.
  //    senderDeviceId stays empty: the receiver authenticates via the signature
  //    against the conversation's peer identity, not this transport field.
  final innerRecord = SealedInner(
    conversationId: conversationId,
    envelopeType: EnvelopeType.deliveredReceipt,
    senderDeviceId: '',
    ciphertext: receipt.encode(),
  ).encode();
  final List<int> blob;
  try {
    blob = await (sealer ?? SealedEnvelope())
        .seal(recipientX25519PubKey: keys.x25519Pub, plaintext: innerRecord);
  } catch (_) {
    return false;
  }

  // 5. Deposit on the UNAUTHENTICATED sealed path (no JWT → the server never
  //    sees us), presenting the sender's UAK so it accepts the blob for the
  //    sender's device.
  try {
    await api.submitSealedUnauthenticated(
      SubmitMessagePayload(
        conversationId: '',
        envelopeType: EnvelopeType.sealed,
        recipientAccountId: '',
        recipientDeviceId: senderDeviceId,
        ciphertext: blob,
        // Protocol-only: without this the server pushes the original sender a
        // phantom "New message" banner for every closed-app delivery receipt.
        pushKind: PushKind.silent,
      ),
      keys.uak,
    );
    return true;
  } catch (_) {
    return false;
  }
}
