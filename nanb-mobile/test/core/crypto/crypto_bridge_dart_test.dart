import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/core/crypto/conversation_crypto_state.dart';
import 'package:nanb_chat/core/crypto/crypto_bridge.dart';
import 'package:nanb_chat/core/crypto/crypto_bridge_dart.dart';
import 'package:nanb_chat/core/secure_storage/secure_storage.dart';

void main() {
  group('CryptoBridgeDart', () {
    late SecureStorageInMemory storage;
    late CryptoBridgeDart bridge;
    final algorithm = Ed25519();

    setUp(() {
      storage = SecureStorageInMemory();
      bridge = CryptoBridgeDart(storage: storage);
    });

    test('generateIdentity returns a 32-byte public key', () async {
      final handle = await bridge.generateIdentity();
      expect(handle.publicKey, hasLength(32));
      expect(handle.id, startsWith('identity-'));
    });

    test('generateIdentity persists seed + public key + handle id', () async {
      await bridge.generateIdentity();
      expect(await storage.getString('crypto.identity.seed.b64'), isNotNull);
      expect(await storage.getString('crypto.identity.pub.b64'), isNotNull);
      expect(await storage.getString('crypto.identity.handle_id'), isNotNull);
    });

    test('two generate calls produce different keypairs', () async {
      final a = await bridge.generateIdentity();
      // simulate restart by replacing the bridge but keeping storage
      final fresh = CryptoBridgeDart(storage: storage);
      final b = await fresh.generateIdentity();
      expect(a.publicKey, isNot(equals(b.publicKey)));
    });

    test('unidentifiedAccessKey is 32 bytes and deterministic', () async {
      await bridge.generateIdentity();
      final uak1 = await bridge.unidentifiedAccessKey();
      final uak2 = await bridge.unidentifiedAccessKey();
      expect(uak1, hasLength(32));
      expect(uak2, equals(uak1), reason: 'derived, not random — stable');
    });

    test('unidentifiedAccessCommitment is SHA-256 of the UAK', () async {
      await bridge.generateIdentity();
      final uak = await bridge.unidentifiedAccessKey();
      final commitment = await bridge.unidentifiedAccessCommitment();
      final expected = (await Sha256().hash(uak)).bytes;
      expect(commitment, equals(expected));
      expect(commitment, hasLength(32));
    });

    test('a different identity yields a different UAK', () async {
      await bridge.generateIdentity();
      final uakA = await bridge.unidentifiedAccessKey();
      final fresh = CryptoBridgeDart(storage: SecureStorageInMemory());
      await fresh.generateIdentity();
      final uakB = await fresh.unidentifiedAccessKey();
      expect(uakA, isNot(equals(uakB)));
    });

    test('signWithIdentity produces a 64-byte Ed25519 signature', () async {
      final handle = await bridge.generateIdentity();
      final sig = await bridge.signWithIdentity(handle, [1, 2, 3, 4, 5]);
      expect(sig, hasLength(64));
    });

    test('signWithIdentity produces a signature that verifies with the returned public key', () async {
      final handle = await bridge.generateIdentity();
      final payload = utf8.encode('canonical-test-payload');
      final sig = await bridge.signWithIdentity(handle, payload);

      final ok = await algorithm.verify(
        payload,
        signature: Signature(
          sig,
          publicKey: SimplePublicKey(handle.publicKey, type: KeyPairType.ed25519),
        ),
      );
      expect(ok, isTrue);
    });

    test('different payloads sign to different signatures', () async {
      final handle = await bridge.generateIdentity();
      final s1 = await bridge.signWithIdentity(handle, utf8.encode('one'));
      final s2 = await bridge.signWithIdentity(handle, utf8.encode('two'));
      expect(s1, isNot(equals(s2)));
    });

    test('currentIdentity returns null when no identity stored', () async {
      expect(await bridge.currentIdentity(), isNull);
    });

    test('currentIdentity returns the same handle after generateIdentity', () async {
      final handle = await bridge.generateIdentity();
      final cur = await bridge.currentIdentity();
      expect(cur, isNotNull);
      expect(cur!.id, equals(handle.id));
      expect(cur.publicKey, equals(handle.publicKey));
    });

    test('currentIdentity rehydrates from storage on a fresh bridge instance', () async {
      final handle = await bridge.generateIdentity();
      // Drop the in-memory cache by constructing a new bridge over the same storage.
      final fresh = CryptoBridgeDart(storage: storage);
      final cur = await fresh.currentIdentity();
      expect(cur, isNotNull);
      expect(cur!.id, equals(handle.id));
      expect(cur.publicKey, equals(handle.publicKey));
    });

    test('signWithIdentity works on a rehydrated bridge', () async {
      final handle = await bridge.generateIdentity();
      final freshBridge = CryptoBridgeDart(storage: storage);
      final cur = await freshBridge.currentIdentity();
      final payload = utf8.encode('hello');
      final sig = await freshBridge.signWithIdentity(cur!, payload);

      final ok = await algorithm.verify(
        payload,
        signature: Signature(
          sig,
          publicKey: SimplePublicKey(handle.publicKey, type: KeyPairType.ed25519),
        ),
      );
      expect(ok, isTrue);
    });

    test('signWithIdentity rejects a handle that does not match storage', () async {
      await bridge.generateIdentity();
      const wrong = IdentityHandle(id: 'wrong-id', publicKey: [], x25519PublicKey: []);
      expect(() => bridge.signWithIdentity(wrong, [1, 2, 3]),
          throwsA(isA<StateError>()));
    });

    test('signWithIdentity throws when no identity stored', () async {
      const wrong = IdentityHandle(id: 'whatever', publicKey: [], x25519PublicKey: []);
      expect(() => bridge.signWithIdentity(wrong, [1, 2, 3]),
          throwsA(isA<StateError>()));
    });

    test('mintKeyPackage returns 256 opaque bytes', () async {
      final handle = await bridge.generateIdentity();
      final kp = await bridge.mintKeyPackage(handle);
      expect(kp, hasLength(256));
    });

    test('wipe() removes the persisted identity', () async {
      await bridge.generateIdentity();
      await bridge.wipe();
      expect(await bridge.currentIdentity(), isNull);
      expect(await storage.getString('crypto.identity.seed.b64'), isNull);
    });

    test('generateIdentity with the same seed yields the same public key', () async {
      final seed = List<int>.generate(32, (i) => (i * 7 + 3) & 0xFF);
      final a = await bridge.generateIdentity(seed: seed);

      final freshStorage = SecureStorageInMemory();
      final fresh = CryptoBridgeDart(storage: freshStorage);
      final b = await fresh.generateIdentity(seed: seed);

      expect(a.publicKey, equals(b.publicKey));
    });

    test('generateIdentity tolerates seeds longer than 32 bytes (BIP-39 64-byte)', () async {
      final seed = List<int>.generate(64, (i) => (i * 11) & 0xFF);
      final handle = await bridge.generateIdentity(seed: seed);
      expect(handle.publicKey, hasLength(32));
      // signing still works.
      final sig = await bridge.signWithIdentity(handle, [1, 2, 3]);
      expect(sig, hasLength(64));
    });

    test('generateIdentity with different seeds yields different public keys', () async {
      final seedA = List<int>.filled(32, 1);
      final seedB = List<int>.filled(32, 2);
      final a = await bridge.generateIdentity(seed: seedA);
      final fresh = CryptoBridgeDart(storage: SecureStorageInMemory());
      final b = await fresh.generateIdentity(seed: seedB);
      expect(a.publicKey, isNot(equals(b.publicKey)));
    });

    test('generateIdentity returns a non-empty 32-byte X25519 pub key', () async {
      final handle = await bridge.generateIdentity();
      expect(handle.x25519PublicKey, hasLength(32));
    });

    test('same BIP-39 seed yields the same X25519 pub key (deterministic restore)', () async {
      final seed = List<int>.generate(64, (i) => (i * 13 + 7) & 0xFF);
      final a = await bridge.generateIdentity(seed: seed);
      final fresh = CryptoBridgeDart(storage: SecureStorageInMemory());
      final b = await fresh.generateIdentity(seed: seed);
      expect(a.x25519PublicKey, equals(b.x25519PublicKey));
    });

    test('Ed25519 and X25519 keys are distinct (domain-separated derivation)', () async {
      final seed = List<int>.generate(64, (i) => i & 0xFF);
      final handle = await bridge.generateIdentity(seed: seed);
      expect(handle.x25519PublicKey, isNot(equals(handle.publicKey)));
    });
  });

  group('v1.1 ratchet — ECDH-seeded forward-secret encrypt/decrypt', () {
    late SecureStorageInMemory aliceStorage;
    late SecureStorageInMemory bobStorage;
    late CryptoBridgeDart alice;
    late CryptoBridgeDart bob;
    late IdentityHandle aliceHandle;
    late IdentityHandle bobHandle;

    setUp(() async {
      aliceStorage = SecureStorageInMemory();
      bobStorage = SecureStorageInMemory();
      alice = CryptoBridgeDart(storage: aliceStorage);
      bob = CryptoBridgeDart(storage: bobStorage);
      aliceHandle = await alice.generateIdentity();
      bobHandle = await bob.generateIdentity();
    });

    Future<({ConversationCryptoState a, ConversationCryptoState b})> initStates(
      String convoId,
    ) async {
      final aState = await alice.initConversationCrypto(
        conversationId: convoId,
        peerX25519PubKey: bobHandle.x25519PublicKey,
      );
      final bState = await bob.initConversationCrypto(
        conversationId: convoId,
        peerX25519PubKey: aliceHandle.x25519PublicKey,
      );
      return (a: aState, b: bState);
    }

    test('init produces matching chains on both peers', () async {
      final s = await initStates('c');
      expect(s.a.sendChainKey, equals(s.b.recvChainKey));
      expect(s.a.recvChainKey, equals(s.b.sendChainKey));
      expect(s.a.sendCounter, equals(0));
      expect(s.b.recvCounter, equals(0));
    });

    test('init rejects empty peer key', () async {
      expect(
        () => alice.initConversationCrypto(
          conversationId: 'c',
          peerX25519PubKey: const [],
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('Alice encrypts → Bob decrypts the same plaintext', () async {
      final s = await initStates('convo-1');
      final enc = await alice.encryptMessage(
        state: s.a,
        plaintext: const [104, 101, 108, 108, 111],
      );
      final dec = await bob.decryptMessage(state: s.b, ciphertext: enc.ciphertext);
      expect(dec.plaintext, equals([104, 101, 108, 108, 111]));
    });

    test('ciphertext is shaped [counter 4][nonce 12][cipher][tag 16]', () async {
      final s = await initStates('c');
      final enc = await alice.encryptMessage(state: s.a, plaintext: const [1, 2, 3]);
      // 4 counter + 12 nonce + 3 cipher + 16 tag = 35 bytes.
      expect(enc.ciphertext.length, equals(35));
    });

    test('encrypt advances the send chain', () async {
      final s = await initStates('c');
      final enc = await alice.encryptMessage(state: s.a, plaintext: const [1]);
      expect(enc.newState.sendCounter, equals(1));
      expect(enc.newState.sendChainKey, isNot(equals(s.a.sendChainKey)));
    });

    test('forward secrecy: state advanced past N cannot decrypt N (replay rejected)', () async {
      final s = await initStates('c');
      final enc0 = await alice.encryptMessage(state: s.a, plaintext: const [10]);
      final enc1 = await alice.encryptMessage(state: enc0.newState, plaintext: const [11]);
      final dec0 = await bob.decryptMessage(state: s.b, ciphertext: enc0.ciphertext);
      expect(dec0.plaintext, equals([10]));
      expect(
        () => bob.decryptMessage(state: dec0.newState, ciphertext: enc0.ciphertext),
        throwsA(isA<StateError>()),
      );
      final dec1 = await bob.decryptMessage(state: dec0.newState, ciphertext: enc1.ciphertext);
      expect(dec1.plaintext, equals([11]));
    });

    test('out-of-order within skip window decrypts and advances the chain', () async {
      final s = await initStates('c');
      final enc0 = await alice.encryptMessage(state: s.a, plaintext: const [10]);
      final enc1 = await alice.encryptMessage(state: enc0.newState, plaintext: const [11]);
      final enc2 = await alice.encryptMessage(state: enc1.newState, plaintext: const [12]);
      final dec2 = await bob.decryptMessage(state: s.b, ciphertext: enc2.ciphertext);
      expect(dec2.plaintext, equals([12]));
      expect(dec2.newState.recvCounter, equals(3));
    });

    test('OOO arrival recovers via the skipped-key cache', () async {
      final s = await initStates('c');
      final enc0 = await alice.encryptMessage(state: s.a, plaintext: const [10]);
      final enc1 = await alice.encryptMessage(state: enc0.newState, plaintext: const [11]);
      final enc2 = await alice.encryptMessage(state: enc1.newState, plaintext: const [12]);

      // Bob receives 2 first — chain advances past 0 and 1, but those keys
      // get cached.
      final dec2 = await bob.decryptMessage(state: s.b, ciphertext: enc2.ciphertext);
      expect(dec2.plaintext, equals([12]));

      // Now the late-arriving 0 and 1 still decrypt via the cache.
      final dec0 = await bob.decryptMessage(state: dec2.newState, ciphertext: enc0.ciphertext);
      expect(dec0.plaintext, equals([10]));
      // chain state unchanged after OOO recovery (recvCounter stays at 3).
      expect(dec0.newState.recvCounter, equals(3));

      final dec1 = await bob.decryptMessage(state: dec2.newState, ciphertext: enc1.ciphertext);
      expect(dec1.plaintext, equals([11]));
    });

    test('cached skipped key is consumed on first use (no double-decrypt)', () async {
      final s = await initStates('c');
      final enc0 = await alice.encryptMessage(state: s.a, plaintext: const [10]);
      final enc1 = await alice.encryptMessage(state: enc0.newState, plaintext: const [11]);
      // Bob gets 1 first, caches key for 0.
      final dec1 = await bob.decryptMessage(state: s.b, ciphertext: enc1.ciphertext);
      expect(dec1.plaintext, equals([11]));
      // Decrypt 0 from cache — succeeds.
      final dec0a = await bob.decryptMessage(state: dec1.newState, ciphertext: enc0.ciphertext);
      expect(dec0a.plaintext, equals([10]));
      // Replay of 0 must now fail — the cached key was consumed.
      expect(
        () => bob.decryptMessage(state: dec1.newState, ciphertext: enc0.ciphertext),
        throwsA(isA<StateError>()),
      );
    });

    test('skipped-key cache is bounded — oldest counters evicted past the cap', () async {
      // Arrange: two consecutive OOO arrivals each contribute skipped keys
      // to the cache. Their combined size exceeds maxCachedKeysPerConversation,
      // which forces eviction of the oldest counters.
      // Use 20 + 20 = 40 cached keys, capped to 32 → drops the 8 oldest
      // (counters 0..7). Slots 8..19 + 21..39 should still recover; slots
      // 0..7 are gone.
      final s = await initStates('c');
      var aState = s.a;
      final ciphertexts = <List<int>>[];
      for (var i = 0; i <= 40; i++) {
        final enc = await alice.encryptMessage(state: aState, plaintext: [i & 0xff]);
        ciphertexts.add(enc.ciphertext);
        aState = enc.newState;
      }

      // Bob first receives counter=20 — caches keys 0..19 (20 entries).
      final dec20 = await bob.decryptMessage(state: s.b, ciphertext: ciphertexts[20]);
      expect(dec20.plaintext, equals([20]));

      // Then Bob receives counter=40 — fast-forwards 20 more (skipping
      // 21..39), caching those 20 keys. Total 40 > cap=32 → 8 oldest evicted.
      final dec40 = await bob.decryptMessage(state: dec20.newState, ciphertext: ciphertexts[40]);
      expect(dec40.plaintext, equals([40]));

      // Slots 8..19 and 21..39 still recoverable.
      for (final i in [8, 19, 21, 39]) {
        final back = await bob.decryptMessage(state: dec40.newState, ciphertext: ciphertexts[i]);
        expect(back.plaintext, equals([i & 0xff]));
      }
      // Slot 0 was evicted — replay/OOO recovery fails.
      expect(
        () => bob.decryptMessage(state: dec40.newState, ciphertext: ciphertexts[0]),
        throwsA(isA<StateError>()),
      );
    });

    test('skip beyond the window throws StateError on an established chain', () async {
      final s = await initStates('c');
      // Establish the chain first: once recvCounter > 0 the tight 32-message
      // window applies (the larger catch-up window is only for a fresh chain).
      final enc0 = await alice.encryptMessage(state: s.a, plaintext: const [1]);
      final bAfter0 =
          await bob.decryptMessage(state: s.b, ciphertext: enc0.ciphertext);
      expect(bAfter0.newState.recvCounter, equals(1));

      var aState = enc0.newState;
      for (var i = 0; i < CryptoBridgeDart.maxSkipWindow + 5; i++) {
        final enc = await alice.encryptMessage(state: aState, plaintext: const [9]);
        aState = enc.newState;
      }
      final farFuture = await alice.encryptMessage(state: aState, plaintext: const [42]);
      expect(
        () => bob.decryptMessage(
            state: bAfter0.newState, ciphertext: farFuture.ciphertext),
        throwsA(isA<StateError>()),
      );
    });

    test('a freshly seeded recv chain catches up across a large initial gap',
        () async {
      // Models a brand-new conversation whose peer sent a backlog while we were
      // offline, and the re-key recovery case (a wiped peer re-seeds at 0 and
      // must catch up to our advanced send counter). A fresh chain
      // (recvCounter 0) gets the larger catch-up window.
      final s = await initStates('c');
      var aState = s.a;
      const gap = CryptoBridgeDart.maxSkipWindow + 50; // 82 > the 32 cap
      for (var i = 0; i < gap; i++) {
        final enc = await alice.encryptMessage(state: aState, plaintext: const [9]);
        aState = enc.newState;
      }
      final latest = await alice.encryptMessage(state: aState, plaintext: const [7]);
      final dec = await bob.decryptMessage(state: s.b, ciphertext: latest.ciphertext);
      expect(dec.plaintext, equals([7]));
      expect(dec.newState.recvCounter, equals(gap + 1));
    });

    test('two encryptions of the same plaintext produce different ciphertexts', () async {
      final s = await initStates('c');
      final a = await alice.encryptMessage(state: s.a, plaintext: const [1, 2, 3]);
      final b = await alice.encryptMessage(state: a.newState, plaintext: const [1, 2, 3]);
      expect(a.ciphertext, isNot(equals(b.ciphertext)));
    });

    test('decryption fails with the wrong peer key (different shared secret)', () async {
      final eveHandle = await CryptoBridgeDart(storage: SecureStorageInMemory()).generateIdentity();
      final aState = await alice.initConversationCrypto(
        conversationId: 'c',
        peerX25519PubKey: bobHandle.x25519PublicKey,
      );
      final enc = await alice.encryptMessage(state: aState, plaintext: const [1, 2, 3]);
      final wrongState = await bob.initConversationCrypto(
        conversationId: 'c',
        peerX25519PubKey: eveHandle.x25519PublicKey,
      );
      expect(
        () => bob.decryptMessage(state: wrongState, ciphertext: enc.ciphertext),
        throwsA(anything),
      );
    });

    test('decryption fails when the conversation_id does not match', () async {
      final aA = await alice.initConversationCrypto(
        conversationId: 'convo-A',
        peerX25519PubKey: bobHandle.x25519PublicKey,
      );
      final enc = await alice.encryptMessage(state: aA, plaintext: const [1, 2, 3]);
      final bB = await bob.initConversationCrypto(
        conversationId: 'convo-B',
        peerX25519PubKey: aliceHandle.x25519PublicKey,
      );
      expect(
        () => bob.decryptMessage(state: bB, ciphertext: enc.ciphertext),
        throwsA(anything),
      );
    });

    test('decryption fails on a tampered byte', () async {
      final s = await initStates('c');
      final enc = await alice.encryptMessage(state: s.a, plaintext: const [1, 2, 3]);
      final tampered = List<int>.from(enc.ciphertext);
      tampered[24] ^= 0x01;
      expect(
        () => bob.decryptMessage(state: s.b, ciphertext: tampered),
        throwsA(anything),
      );
    });

    test('init works after restart (X25519 priv reload from storage)', () async {
      final freshAlice = CryptoBridgeDart(storage: aliceStorage);
      final restored = await freshAlice.initConversationCrypto(
        conversationId: 'after-restart',
        peerX25519PubKey: bobHandle.x25519PublicKey,
      );
      final original = await alice.initConversationCrypto(
        conversationId: 'after-restart',
        peerX25519PubKey: bobHandle.x25519PublicKey,
      );
      expect(restored.sendChainKey, equals(original.sendChainKey));
      expect(restored.recvChainKey, equals(original.recvChainKey));
    });

    test('init throws when no X25519 priv has been stored', () async {
      final empty = CryptoBridgeDart(storage: SecureStorageInMemory());
      expect(
        () => empty.initConversationCrypto(
          conversationId: 'c',
          peerX25519PubKey: bobHandle.x25519PublicKey,
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('decryptMessage rejects ciphertext shorter than counter+nonce+tag', () async {
      final s = await initStates('c');
      expect(
        () => alice.decryptMessage(
          state: s.a,
          ciphertext: List<int>.filled(20, 0), // < 4 + 12 + 16
        ),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('CryptoBridge interface — server claim format compatibility', () {
    test('server-side username claim payload verifies with this Dart impl', () async {
      // This mirrors `internal/identity.UsernameClaimPayload` on the server:
      //   prefix "nanb-username-claim-v1:" + username + '|' + identityPubKey
      // If the bytes line up, the server's ed25519.Verify will accept the
      // signature this bridge produces.
      final storage = SecureStorageInMemory();
      final bridge = CryptoBridgeDart(storage: storage);
      final algorithm = Ed25519();

      final handle = await bridge.generateIdentity();

      final payload = <int>[];
      payload.addAll(utf8.encode('nanb-username-claim-v1:'));
      payload.addAll(utf8.encode('alice'));
      payload.add(0x7C); // '|'
      payload.addAll(handle.publicKey);

      final signature = await bridge.signWithIdentity(handle, payload);

      final ok = await algorithm.verify(
        payload,
        signature: Signature(
          signature,
          publicKey: SimplePublicKey(handle.publicKey, type: KeyPairType.ed25519),
        ),
      );
      expect(ok, isTrue);
    });
  });
}
