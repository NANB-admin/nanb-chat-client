import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Opens a sealed-sender outer envelope addressed to *this* device, returning
/// the inner bytes. A narrow seam (separate from `CryptoBridge`) so the receive
/// path can unwrap without every `CryptoBridge` test fake having to implement
/// it — only the real bridges (which hold this device's X25519 private key) do.
/// Implemented by `CryptoBridgeDart` and surfaced through `CryptoBridgeComposite`.
abstract interface class SealOpener {
  /// Throws if [sealed] isn't openable by this device (wrong target / corrupt /
  /// unsupported version).
  Future<List<int>> openSealed(List<int> sealed);
}

/// Sealed-sender Phase 1 — the **outer** encryption layer (see
/// `docs/sealed-sender-design.md`).
///
/// The inner E2EE ciphertext (an MLS `PrivateMessage` or a ratchet message)
/// can't go to the server as-is: an MLS message carries its `group_id` + `epoch`
/// in the clear (RFC 9420 §6.3), so a server that stores the raw message can
/// re-link conversations from the payload — sender attribution alone (Phase 0)
/// doesn't hide the social graph. This layer wraps the inner payload so the
/// server sees only opaque bytes: no group_id, no sender, no conversation.
///
/// Encryption is to the **recipient device's** static X25519 key (already
/// published in `devices`, fetched like a key package). NANb already fans a send
/// out once per recipient device, so sealing fits that loop. A fresh ephemeral
/// keypair per message gives per-message forward secrecy against later
/// compromise of the ephemeral.
///
/// **Size padding (v2).** The server can't see the sender or conversation, but it
/// still sees each sealed blob's *length* — enough to fingerprint message *type*
/// (a one-word reply vs a receipt vs a paragraph vs a media descriptor). So the
/// AEAD **plaintext** is padded up to a fixed [_padBuckets] bucket before
/// encryption, with its true length carried in an encrypted 4-byte prefix that
/// `open()` strips. The ciphertext length on the wire then reveals only which
/// bucket a message fell in, not its real size. Media bytes go to S3 separately,
/// so sealed blobs stay small and the buckets stay cheap.
///
/// Wire format:
/// ```
///   byte  0       version (0x02 padded; 0x01 = legacy unpadded, still openable)
///   bytes 1..=32  ephemeral X25519 public key (32)
///   bytes 33..=44 AEAD nonce (12)
///   bytes 45..    AES-256-GCM ciphertext, with the 16-byte tag as the suffix
/// ```
/// For v2 the AEAD plaintext (before encryption) is:
/// ```
///   bytes 0..=3   real plaintext length, big-endian uint32
///   bytes 4..     the plaintext, then zero padding to the bucket boundary
/// ```
/// Shared secret = ECDH(ephemeral_priv, recipient_pub); AEAD key =
/// HKDF-SHA256(shared, salt=[_salt], info=recipient_pub) — binding the key to
/// the recipient's identity so a blob can't be re-pointed at another device.
class SealedEnvelope {
  SealedEnvelope({X25519? x25519, AesGcm? aead, Hkdf? hkdf})
      : _x25519 = x25519 ?? X25519(),
        _aead = aead ?? AesGcm.with256bits(),
        _hkdf = hkdf ?? Hkdf(hmac: Hmac.sha256(), outputLength: 32);

  final X25519 _x25519;
  final AesGcm _aead;
  final Hkdf _hkdf;

  /// Legacy unpadded format. Still **openable** (a blob queued by a pre-v2
  /// sender during a rollout), but never emitted — `seal` always writes [paddedVersion].
  static const int version = 0x01;

  /// Size-padded format (current). The AEAD plaintext is `len(4)||plaintext||zeros`.
  static const int paddedVersion = 0x02;

  static const int _pubLen = 32;
  static const int _nonceLen = 12;
  static const int _tagLen = 16;
  static const int _headerLen = 1 + _pubLen + _nonceLen; // version+ephPub+nonce
  static const int _minLen = _headerLen + _tagLen; // empty plaintext still tags

  /// Big-endian uint32 real-length prefix on the v2 AEAD plaintext.
  static const int _lenPrefix = 4;

  /// Fixed buckets (bytes of len-prefix + plaintext) the AEAD plaintext is padded
  /// up to, so the wire ciphertext length leaks only the bucket. Beyond the
  /// largest bucket, round up to the next multiple of it — a multi-KB message
  /// already self-identifies by size, and these stay far under the server's
  /// per-message cap (1 MiB) since media never rides inline.
  static const List<int> _padBuckets = [256, 1024, 4096, 16384, 65536];

  /// Smallest bucket that holds [n] bytes, else [n] rounded up to a multiple of
  /// the largest bucket.
  static int bucketFor(int n) {
    for (final b in _padBuckets) {
      if (n <= b) return b;
    }
    final top = _padBuckets.last;
    return ((n + top - 1) ~/ top) * top;
  }

  /// Domain-separation salt for the HKDF. Bump the version byte (and this) if the
  /// KDF/construction ever changes.
  static final List<int> _salt =
      Uint8List.fromList('nanb/sealed-sender/v1'.codeUnits);

  /// Seals [plaintext] for the device owning [recipientX25519PubKey] (32 raw
  /// bytes). Returns the opaque wire blob the server stores/relays.
  Future<Uint8List> seal({
    required List<int> recipientX25519PubKey,
    required List<int> plaintext,
  }) async {
    if (recipientX25519PubKey.length != _pubLen) {
      throw ArgumentError('recipient X25519 pub key must be 32 bytes');
    }
    final ephemeral = await _x25519.newKeyPair();
    final ephemeralPub = await ephemeral.extractPublicKey();
    final key = await _deriveKey(
      keyPair: ephemeral,
      remotePub: recipientX25519PubKey,
      recipientPub: recipientX25519PubKey,
    );
    final box = await _aead.encrypt(_pad(plaintext), secretKey: key);

    final out = BytesBuilder(copy: false)
      ..addByte(paddedVersion)
      ..add(ephemeralPub.bytes)
      ..add(box.nonce)
      ..add(box.cipherText)
      ..add(box.mac.bytes);
    return out.toBytes();
  }

  /// Builds the v2 AEAD plaintext: a big-endian uint32 real length, the
  /// [plaintext], then zero padding out to the next [bucketFor] boundary.
  static Uint8List _pad(List<int> plaintext) {
    final n = plaintext.length;
    final out = Uint8List(bucketFor(_lenPrefix + n)); // zero-filled
    out[0] = (n >> 24) & 0xFF;
    out[1] = (n >> 16) & 0xFF;
    out[2] = (n >> 8) & 0xFF;
    out[3] = n & 0xFF;
    out.setRange(_lenPrefix, _lenPrefix + n, plaintext);
    return out;
  }

  /// Inverse of [_pad]: reads the length prefix and slices off the padding.
  static Uint8List _unpad(List<int> padded) {
    if (padded.length < _lenPrefix) {
      throw const FormatException('sealed plaintext missing length prefix');
    }
    final n =
        (padded[0] << 24) | (padded[1] << 16) | (padded[2] << 8) | padded[3];
    if (_lenPrefix + n > padded.length) {
      throw const FormatException('sealed plaintext length prefix out of range');
    }
    return Uint8List.fromList(padded.sublist(_lenPrefix, _lenPrefix + n));
  }

  /// Opens a [sealed] blob with the recipient device's X25519 **private** key
  /// (32 raw bytes, as stored). Throws on a malformed blob, a wrong key, or a
  /// tampered ciphertext (AEAD tag mismatch).
  Future<Uint8List> open({
    required List<int> recipientX25519PrivKey,
    required List<int> sealed,
  }) async {
    if (sealed.length < _minLen) {
      throw const FormatException('sealed envelope too short');
    }
    final ver = sealed[0];
    if (ver != version && ver != paddedVersion) {
      throw FormatException('unsupported sealed-envelope version $ver');
    }
    final ephemeralPub = sealed.sublist(1, 1 + _pubLen);
    final nonce = sealed.sublist(1 + _pubLen, _headerLen);
    final mac = Mac(sealed.sublist(sealed.length - _tagLen));
    final cipherText = sealed.sublist(_headerLen, sealed.length - _tagLen);

    final recipientKeyPair =
        await _x25519.newKeyPairFromSeed(List<int>.from(recipientX25519PrivKey));
    final recipientPub = await recipientKeyPair.extractPublicKey();
    final key = await _deriveKey(
      keyPair: recipientKeyPair,
      remotePub: ephemeralPub,
      recipientPub: recipientPub.bytes,
    );
    final clear = await _aead.decrypt(
      SecretBox(cipherText, nonce: nonce, mac: mac),
      secretKey: key,
    );
    // v1 blobs carry the plaintext directly; v2 carries len-prefix + padding.
    return ver == paddedVersion ? _unpad(clear) : Uint8List.fromList(clear);
  }

  /// ECDH([keyPair], [remotePub]) → HKDF, bound to [recipientPub] as info so
  /// both sides derive the same key only for the intended recipient. Both seal
  /// and open pass the recipient's *static* pub as info.
  Future<SecretKey> _deriveKey({
    required SimpleKeyPair keyPair,
    required List<int> remotePub,
    required List<int> recipientPub,
  }) async {
    final shared = await _x25519.sharedSecretKey(
      keyPair: keyPair,
      remotePublicKey: SimplePublicKey(remotePub, type: KeyPairType.x25519),
    );
    return _hkdf.deriveKey(secretKey: shared, nonce: _salt, info: recipientPub);
  }
}
