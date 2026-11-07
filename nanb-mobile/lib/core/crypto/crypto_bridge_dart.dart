import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../secure_storage/secure_storage.dart';
import 'add_member_result.dart';
import 'conversation_crypto_state.dart';
import 'crypto_bridge.dart';
import 'decrypt_mls_result.dart';
import 'sealed_envelope.dart';
import 'unidentified_access.dart';

/// Pure-Dart implementation of [CryptoBridge].
///
/// **Identity layer (Plan 6a):** Ed25519 keypair (seedable from BIP-39) for
/// signing username claims + session challenges.
///
/// **Content E2EE (Plan 13):** X25519 keypair derived deterministically from
/// the BIP-39 seed via HKDF; ECDH against the peer's X25519 pub key seeds
/// the per-conversation ratchet root.
///
/// **Forward secrecy (Plan 13.1):** Per-conversation symmetric ratchet with
/// two chains (send + recv), seeded by canonical lex-sort of the two
/// X25519 pub keys so both peers compute matching states. Each message
/// derives a one-shot message key; the chain advances and the prior chain
/// key is discarded. Compromise at message N never exposes earlier
/// messages on the same chain. Out-of-order delivery within a 32-message
/// skip window is tolerated.
///
/// Out of scope (Plan 6 full / CoreCrypto MLS):
///   - DH ratchet for post-compromise security.
///   - Group operations (1:1 only).
///   - RFC 9420 compliance.
class CryptoBridgeDart
    implements CryptoBridge, SealOpener, UnidentifiedAccessProvider {
  CryptoBridgeDart({required SecureStorage storage}) : _storage = storage;

  final SecureStorage _storage;
  final Ed25519 _ed25519 = Ed25519();
  final X25519 _x25519 = X25519();
  final AesGcm _aead = AesGcm.with256bits();
  final Hkdf _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
  final SealedEnvelope _sealedCodec = SealedEnvelope();

  /// Sealed-sender (Phase 1): opens an outer envelope sealed to THIS device by
  /// decrypting with this device's X25519 private key. The registered X25519 pub
  /// (what senders seal to) is derived from this same keypair, so a blob
  /// correctly targeted at us always opens. Throws on a wrong-target/corrupt blob.
  @override
  Future<List<int>> openSealed(List<int> sealed) async {
    final keyPair = await _ensureXLoaded();
    final priv = await keyPair.extractPrivateKeyBytes();
    return _sealedCodec.open(recipientX25519PrivKey: priv, sealed: sealed);
  }

  /// Sealed-sender Phase 2 (unidentified access): the UAK is HKDF(x25519_priv,
  /// info="nanb-uak-v1"). Deriving it from the phrase-derived, immutable X25519
  /// identity makes it stable across reinstalls/restore with no stored state,
  /// while HKDF's one-wayness means the UAK never exposes the private key.
  Future<List<int>> _uak() async {
    final keyPair = await _ensureXLoaded();
    final xPriv = await keyPair.extractPrivateKeyBytes();
    return _hkdfBytes(SecretKey(xPriv), 'nanb-uak-v1');
  }

  @override
  Future<List<int>> unidentifiedAccessKey() => _uak();

  @override
  Future<List<int>> unidentifiedAccessCommitment() async {
    final uak = await _uak();
    final digest = await Sha256().hash(uak);
    return digest.bytes;
  }

  /// Maximum number of skipped messages we'll fast-forward an **established**
  /// recv chain across before rejecting the inbound message. Keeps a malicious
  /// peer from forcing unbounded HKDF work.
  static const int maxSkipWindow = 32;

  /// Larger one-time catch-up allowed only for a **freshly seeded** recv chain
  /// (`recvCounter == 0`). Two legitimate cases need it: a brand-new
  /// conversation whose peer sent a backlog while we were offline, and re-key
  /// recovery (a peer wiped its device and re-seeded at counter 0 while our
  /// send counter is already well ahead — the wiped side must catch up to it).
  /// Bounded so even a hostile first contact can only force this many HKDF
  /// steps once, before the chain advances and the tight window above applies.
  static const int maxInitialCatchupWindow = 1024;

  /// Per-conversation cap on cached skipped message keys. Bounds memory and
  /// matches the skip-window so a single OOO arrival can recover any of the
  /// in-flight messages.
  static const int maxCachedKeysPerConversation = 32;

  static const String _kEdSeed = 'crypto.identity.seed.b64';
  static const String _kEdPub = 'crypto.identity.pub.b64';
  static const String _kHandleId = 'crypto.identity.handle_id';
  static const String _kXSeed = 'crypto.identity.x25519_priv.b64';
  static const String _kXPub = 'crypto.identity.x25519_pub.b64';

  // In-memory cache so we don't re-derive the keypair on every sign/encrypt.
  SimpleKeyPair? _cachedEdKeyPair;
  SimpleKeyPair? _cachedXKeyPair;
  IdentityHandle? _cachedHandle;

  /// Skipped message keys for out-of-order delivery — keyed by conversationId
  /// then by the wire counter. Lost on restart (in-memory only) which is
  /// fine: across-restart OOO arrivals are rare and dropping them costs the
  /// user one un-decryptable message instead of all of them.
  final Map<String, Map<int, List<int>>> _skippedKeys = {};

  @override
  Future<IdentityHandle> generateIdentity({List<int>? seed}) async {
    final SimpleKeyPair edKeyPair;
    if (seed == null) {
      edKeyPair = await _ed25519.newKeyPair();
    } else {
      final edSeed = seed.length >= 32 ? seed.sublist(0, 32) : seed;
      edKeyPair = await _ed25519.newKeyPairFromSeed(edSeed);
    }
    final edPub = await edKeyPair.extractPublicKey();
    final edSeedBytes = await edKeyPair.extractPrivateKeyBytes();

    final xSeed = seed != null
        ? await _deriveX25519Seed(seed)
        : await _randomBytes(32);
    final xKeyPair = await _x25519.newKeyPairFromSeed(xSeed);
    final xPub = await xKeyPair.extractPublicKey();
    final xPrivBytes = await xKeyPair.extractPrivateKeyBytes();

    final handleId = 'identity-${DateTime.now().toUtc().microsecondsSinceEpoch}';
    await _storage.putString(_kEdSeed, base64.encode(edSeedBytes));
    await _storage.putString(_kEdPub, base64.encode(edPub.bytes));
    await _storage.putString(_kHandleId, handleId);
    await _storage.putString(_kXSeed, base64.encode(xPrivBytes));
    await _storage.putString(_kXPub, base64.encode(xPub.bytes));

    final handle = IdentityHandle(
      id: handleId,
      publicKey: List<int>.from(edPub.bytes),
      x25519PublicKey: List<int>.from(xPub.bytes),
    );
    _cachedEdKeyPair = edKeyPair;
    _cachedXKeyPair = xKeyPair;
    _cachedHandle = handle;
    return handle;
  }

  @override
  Future<IdentityHandle?> currentIdentity() async {
    if (_cachedHandle != null) return _cachedHandle;
    final edPubB64 = await _storage.getString(_kEdPub);
    final handleId = await _storage.getString(_kHandleId);
    if (edPubB64 == null || handleId == null) return null;
    final xPubB64 = await _storage.getString(_kXPub);
    final handle = IdentityHandle(
      id: handleId,
      publicKey: base64.decode(edPubB64),
      x25519PublicKey: xPubB64 != null ? base64.decode(xPubB64) : const [],
    );
    _cachedHandle = handle;
    return handle;
  }

  @override
  Future<List<int>> signWithIdentity(IdentityHandle handle, List<int> payload) async {
    final keyPair = await _ensureEdLoaded(handle);
    final signature = await _ed25519.sign(payload, keyPair: keyPair);
    return List<int>.from(signature.bytes);
  }

  @override
  Future<List<int>> mintKeyPackage(IdentityHandle handle) async {
    // KeyPackage cryptography is deferred to Plan 6 (full MLS). The server
    // accepts opaque non-empty bytes in v1.
    final stamp = DateTime.now().toUtc().microsecondsSinceEpoch & 0xFFFF;
    return [for (var i = 0; i < 256; i++) (i + stamp) & 0xFF];
  }

  @override
  Future<ConversationCryptoState> initConversationCrypto({
    required String conversationId,
    required List<int> peerX25519PubKey,
  }) async {
    if (peerX25519PubKey.isEmpty) {
      throw StateError('crypto: peer X25519 pub key missing — cannot init');
    }
    final myKeyPair = await _ensureXLoaded();
    final myPub = await myKeyPair.extractPublicKey();
    final shared = await _x25519.sharedSecretKey(
      keyPair: myKeyPair,
      remotePublicKey: SimplePublicKey(peerX25519PubKey, type: KeyPairType.x25519),
    );
    final root = await _hkdf.deriveKey(
      secretKey: shared,
      nonce: utf8.encode(conversationId),
      info: utf8.encode('nanb-conv-root-v1'),
    );
    // Canonical chain assignment so both peers compute matching states:
    // the chain "small → large" is keyed by HKDF(root, info="...-S2L-v1") and
    // belongs to whichever side has the lex-smaller X25519 pub key.
    final smallToLarge = await _deriveChainKey(root, 'nanb-chain-S2L-v1');
    final largeToSmall = await _deriveChainKey(root, 'nanb-chain-L2S-v1');
    final iAmSmall = _lexCompare(List<int>.from(myPub.bytes), peerX25519PubKey) < 0;

    return ConversationCryptoState(
      conversationId: conversationId,
      sendCounter: 0,
      sendChainKey: iAmSmall ? smallToLarge : largeToSmall,
      recvCounter: 0,
      recvChainKey: iAmSmall ? largeToSmall : smallToLarge,
    );
  }

  @override
  Future<EncryptResult> encryptMessage({
    required ConversationCryptoState state,
    required List<int> plaintext,
  }) async {
    final messageKey = await _deriveMessageKey(state.sendChainKey);
    final nextChainKey = await _stepChain(state.sendChainKey);

    final nonce = await _randomBytes(12);
    final box = await _aead.encrypt(
      plaintext,
      secretKey: SecretKey(messageKey),
      nonce: nonce,
    );

    final counterBytes = _u32be(state.sendCounter);
    final wire = <int>[
      ...counterBytes,
      ...nonce,
      ...box.cipherText,
      ...box.mac.bytes,
    ];

    final newState = state.copyWith(
      sendCounter: state.sendCounter + 1,
      sendChainKey: nextChainKey,
    );
    return EncryptResult(ciphertext: wire, newState: newState);
  }

  @override
  Future<DecryptResult> decryptMessage({
    required ConversationCryptoState state,
    required List<int> ciphertext,
  }) async {
    if (ciphertext.length < 4 + 12 + 16) {
      throw FormatException('crypto: ciphertext too short (${ciphertext.length})');
    }
    final counter = _readU32be(ciphertext, 0);

    final nonce = ciphertext.sublist(4, 16);
    final macStart = ciphertext.length - 16;
    final cipher = ciphertext.sublist(16, macStart);
    final mac = Mac(ciphertext.sublist(macStart));
    final box = SecretBox(cipher, nonce: nonce, mac: mac);

    // Out-of-order arrival: the message's counter is older than what we've
    // already advanced past. Look it up in the skipped-keys cache.
    if (counter < state.recvCounter) {
      final cached = _skippedKeys[state.conversationId]?[counter];
      if (cached == null) {
        throw StateError('crypto: replay or stale counter ($counter < ${state.recvCounter})');
      }
      final pt = await _aead.decrypt(box, secretKey: SecretKey(cached));
      // Consume the cached key — each one is good for exactly one decrypt.
      _skippedKeys[state.conversationId]!.remove(counter);
      return DecryptResult(
        plaintext: List<int>.from(pt),
        newState: state, // chain state unchanged for OOO recovery
      );
    }

    final skip = counter - state.recvCounter;
    // A never-used recv chain (counter 0) gets the larger catch-up window;
    // every established chain keeps the tight per-message bound.
    final cap =
        state.recvCounter == 0 ? maxInitialCatchupWindow : maxSkipWindow;
    if (skip > cap) {
      throw StateError('crypto: skip window exceeded (skip=$skip, cap=$cap)');
    }

    // Fast-forward the chain through skipped slots, caching each derived
    // message key so a later out-of-order arrival can still decrypt.
    var chain = List<int>.from(state.recvChainKey);
    final cache = _skippedKeys.putIfAbsent(state.conversationId, () => <int, List<int>>{});
    for (var i = 0; i < skip; i++) {
      final skippedKey = await _deriveMessageKey(chain);
      cache[state.recvCounter + i] = skippedKey;
      chain = await _stepChain(chain);
    }
    _evictExcessSkippedKeys(state.conversationId);

    final messageKey = await _deriveMessageKey(chain);
    final nextChain = await _stepChain(chain);

    final pt = await _aead.decrypt(box, secretKey: SecretKey(messageKey));

    final newState = state.copyWith(
      recvCounter: counter + 1,
      recvChainKey: nextChain,
    );
    return DecryptResult(
      plaintext: List<int>.from(pt),
      newState: newState,
    );
  }

  /// If a conversation's skipped-key cache exceeds the cap, evict the
  /// lowest counters first (oldest skipped messages — least likely to ever
  /// be recovered).
  void _evictExcessSkippedKeys(String conversationId) {
    final cache = _skippedKeys[conversationId];
    if (cache == null || cache.length <= maxCachedKeysPerConversation) return;
    final sortedCounters = cache.keys.toList()..sort();
    final removeCount = cache.length - maxCachedKeysPerConversation;
    for (var i = 0; i < removeCount; i++) {
      cache.remove(sortedCounters[i]);
    }
  }

  @override
  void clearConversationCrypto(String conversationId) {
    _skippedKeys.remove(conversationId);
  }

  @override
  Future<void> wipe() async {
    _cachedEdKeyPair = null;
    _cachedXKeyPair = null;
    _cachedHandle = null;
    _skippedKeys.clear();
    await _storage.delete(_kEdSeed);
    await _storage.delete(_kEdPub);
    await _storage.delete(_kHandleId);
    await _storage.delete(_kXSeed);
    await _storage.delete(_kXPub);
  }

  @override
  Future<List<int>?> rawIdentitySeed() async {
    final b64 = await _storage.getString(_kEdSeed);
    if (b64 == null) return null;
    return base64.decode(b64);
  }

  @override
  Future<void> mlsInit() => throw UnimplementedError(
        'CryptoBridgeDart does not implement MLS; use CryptoBridgeNative.');

  @override
  Future<void> mlsEnsureClient(String deviceId) => throw UnimplementedError(
        'CryptoBridgeDart does not implement MLS; use CryptoBridgeNative.');

  @override
  Future<void> mlsInitReadOnly() =>
      throw UnimplementedError('mlsInitReadOnly requires the native MLS bridge');

  @override
  Future<void> mlsWipe() => throw UnimplementedError(
        'CryptoBridgeDart does not implement MLS; use CryptoBridgeNative.');

  /// No MLS store here, so there is nothing that could have been reset — false
  /// rather than a throw, so the replenisher runs unchanged on this bridge.
  @override
  Future<bool> consumeMlsStoreReset() async => false;

  @override
  Future<List<List<int>>> mintKeyPackages({int count = 100}) =>
      throw UnimplementedError(
          'CryptoBridgeDart does not implement MLS; use CryptoBridgeNative.');

  @override
  Future<String> createGroup({required String conversationId}) =>
      throw UnimplementedError(
          'CryptoBridgeDart does not implement MLS; use CryptoBridgeNative.');

  @override
  Future<AddMemberResult> addMember({
    required String groupId,
    required List<int> peerKeyPackage,
  }) =>
      throw UnimplementedError(
          'CryptoBridgeDart does not implement MLS; use CryptoBridgeNative.');

  @override
  Future<AddMemberResult> addMembers({
    required String groupId,
    required List<List<int>> peerKeyPackages,
  }) =>
      throw UnimplementedError(
          'CryptoBridgeDart does not implement MLS; use CryptoBridgeNative.');

  @override
  Future<String> processWelcome(List<int> welcomeBytes) =>
      throw UnimplementedError(
          'CryptoBridgeDart does not implement MLS; use CryptoBridgeNative.');

  @override
  Future<void> processCommit({
    required String groupId,
    required List<int> commitBytes,
  }) =>
      throw UnimplementedError(
          'CryptoBridgeDart does not implement MLS; use CryptoBridgeNative.');

  @override
  Future<int> currentEpoch(String groupId) =>
      throw UnimplementedError(
          'CryptoBridgeDart does not implement MLS; use CryptoBridgeNative.');

  @override
  Future<Set<String>> groupMemberDeviceIds(String groupId) =>
      throw UnimplementedError(
          'CryptoBridgeDart does not implement MLS; use CryptoBridgeNative.');

  @override
  Future<List<int>> encrypt({
    required String groupId,
    required List<int> plaintext,
  }) =>
      throw UnimplementedError(
          'CryptoBridgeDart does not implement MLS; use CryptoBridgeNative.');

  @override
  Future<List<int>> decrypt({
    required String groupId,
    required List<int> ciphertext,
  }) =>
      throw UnimplementedError(
          'CryptoBridgeDart does not implement MLS; use CryptoBridgeNative.');

  @override
  Future<String> replaceGroup({
    required String localGroupId,
    required List<int> foreignWelcome,
  }) =>
      throw UnimplementedError(
          'CryptoBridgeDart does not implement MLS; use CryptoBridgeNative.');

  @override
  Future<void> wipeGroup(String groupId) =>
      throw UnimplementedError(
          'CryptoBridgeDart does not implement MLS; use CryptoBridgeNative.');

  @override
  Future<List<int>> removeMember({
    required String groupId,
    required String targetDeviceId,
  }) =>
      throw UnimplementedError(
          'removeMember requires CoreCrypto native bridge');

  @override
  Future<DecryptMlsResult> decryptAndInspect({
    required String groupId,
    required List<int> ciphertext,
  }) =>
      throw UnimplementedError(
          'decryptAndInspect requires CoreCrypto native bridge');

  Future<SimpleKeyPair> _ensureEdLoaded(IdentityHandle handle) async {
    if (_cachedEdKeyPair != null && _cachedHandle?.id == handle.id) {
      return _cachedEdKeyPair!;
    }
    final seedB64 = await _storage.getString(_kEdSeed);
    final storedHandleId = await _storage.getString(_kHandleId);
    if (seedB64 == null || storedHandleId == null) {
      throw StateError('crypto: no identity stored');
    }
    if (storedHandleId != handle.id) {
      throw StateError('crypto: identity handle mismatch (expected $storedHandleId, got ${handle.id})');
    }
    final seed = base64.decode(seedB64);
    final keyPair = await _ed25519.newKeyPairFromSeed(seed);
    _cachedEdKeyPair = keyPair;
    _cachedHandle = handle;
    return keyPair;
  }

  Future<SimpleKeyPair> _ensureXLoaded() async {
    if (_cachedXKeyPair != null) return _cachedXKeyPair!;
    final seedB64 = await _storage.getString(_kXSeed);
    if (seedB64 == null) {
      throw StateError('crypto: no x25519 priv stored');
    }
    final keyPair = await _x25519.newKeyPairFromSeed(base64.decode(seedB64));
    _cachedXKeyPair = keyPair;
    return keyPair;
  }

  /// One-shot HKDF: `out = HKDF(secret, salt=salt, info=info)`. Empty salt
  /// is the standard "no-salt" HKDF pattern; the info string provides domain
  /// separation between sub-keys derived from the same secret.
  Future<List<int>> _hkdfBytes(SecretKey secret, String info, {List<int> salt = const []}) async {
    final out = await _hkdf.deriveKey(
      secretKey: secret,
      nonce: salt,
      info: utf8.encode(info),
    );
    return out.extractBytes();
  }

  Future<List<int>> _deriveX25519Seed(List<int> bip39Seed) =>
      _hkdfBytes(SecretKey(bip39Seed), 'nanb-x25519-identity-v1');

  Future<List<int>> _deriveChainKey(SecretKey root, String infoLabel) =>
      _hkdfBytes(root, infoLabel);

  /// `message_key = HKDF(chain_key, info="nanb-msg-v1")`
  Future<List<int>> _deriveMessageKey(List<int> chainKey) =>
      _hkdfBytes(SecretKey(chainKey), 'nanb-msg-v1');

  /// `next_chain_key = HKDF(chain_key, info="nanb-step-v1")`
  Future<List<int>> _stepChain(List<int> chainKey) =>
      _hkdfBytes(SecretKey(chainKey), 'nanb-step-v1');

  Future<List<int>> _randomBytes(int n) async {
    final rng = Random.secure();
    return List<int>.generate(n, (_) => rng.nextInt(256));
  }

  static int _lexCompare(List<int> a, List<int> b) {
    final n = a.length < b.length ? a.length : b.length;
    for (var i = 0; i < n; i++) {
      if (a[i] != b[i]) return a[i] - b[i];
    }
    return a.length - b.length;
  }

  static List<int> _u32be(int v) {
    final b = ByteData(4);
    b.setUint32(0, v, Endian.big);
    return b.buffer.asUint8List().toList();
  }

  static int _readU32be(List<int> bytes, int offset) {
    final b = ByteData(4);
    for (var i = 0; i < 4; i++) {
      b.setUint8(i, bytes[offset + i]);
    }
    return b.getUint32(0, Endian.big);
  }
}
