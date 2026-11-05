import 'add_member_result.dart';
import 'conversation_crypto_state.dart';
import 'decrypt_mls_result.dart';

/// Abstraction over the MLS / identity-key engine. Production wiring (after
/// Plan 6 lands the real CoreCrypto native bridge) sits behind this interface;
/// Plan 6a wired a pure-Dart Ed25519 implementation in `crypto_bridge_dart.dart`
/// that handles the identity-key half (real Ed25519 keypair gen + sign +
/// persistence). Plan 13 added X25519 ECDH + AES-GCM content E2EE. Plan 13.1
/// (2026-05-09) added a forward-secret symmetric ratchet on top — encrypt /
/// decrypt now take + return per-conversation chain state.
abstract class CryptoBridge {
  /// Generate a long-term Ed25519 identity keypair, persist its private half,
  /// and return an opaque handle. Dart code never sees the private bytes.
  ///
  /// If `seed` is provided (32 bytes), the keypair is **deterministically**
  /// derived from it — so the same BIP-39 recovery phrase always produces the
  /// same identity, on any device. With no seed, a fresh random keypair is
  /// generated.
  Future<IdentityHandle> generateIdentity({List<int>? seed});

  /// Returns the currently-stored identity handle (the one created by the
  /// most-recent `generateIdentity` whose private key is still on disk), or
  /// null if no identity is stored on this device.
  Future<IdentityHandle?> currentIdentity();

  /// Sign `payload` with the identity keypair behind `handle`.
  Future<List<int>> signWithIdentity(IdentityHandle handle, List<int> payload);

  /// Mint a new MLS KeyPackage for `handle`. Returns the serialised bytes the
  /// server stores in its directory.
  Future<List<int>> mintKeyPackage(IdentityHandle handle);

  /// Derives the initial per-conversation ratchet state from
  /// ECDH(myX25519, peerX25519). Both peers compute matching states because
  /// the chains are seeded by canonical lex ordering of the two pubkeys.
  /// Idempotent — same inputs always give the same output.
  Future<ConversationCryptoState> initConversationCrypto({
    required String conversationId,
    required List<int> peerX25519PubKey,
  });

  /// Encrypt + advance the SEND chain. Caller must persist `newState`.
  /// Wire format: `[counter 4][nonce 12][AES-GCM cipher][tag 16]`.
  Future<EncryptResult> encryptMessage({
    required ConversationCryptoState state,
    required List<int> plaintext,
  });

  /// Decrypt using the wire counter to fast-forward the RECV chain (within
  /// a bounded skip window). Throws on replay (counter <= recvCounter), AEAD
  /// failure, or skip beyond the window. Caller persists `newState` only on
  /// success.
  Future<DecryptResult> decryptMessage({
    required ConversationCryptoState state,
    required List<int> ciphertext,
  });

  /// Drops the in-memory skipped-key cache for `conversationId`. Called when
  /// a conversation is cleared / deleted so the bridge doesn't leak keys
  /// across sessions of the same chat. Persistent state is owned by the
  /// caller (AppDatabase); this only touches in-memory cache.
  void clearConversationCrypto(String conversationId);

  /// Forget the persisted identity and any in-memory keypair cache. Used by
  /// the settings "Delete account" handler to fully reset local state.
  Future<void> wipe();

  /// Read the persisted 32-byte BIP-39-derived identity seed from
  /// SecureStorage. Used by [CryptoBridgeComposite.mlsInit] to forward
  /// the seed to the native CoreCrypto store-key derivation.
  ///
  /// Returns null when no identity has been generated yet.
  Future<List<int>?> rawIdentitySeed();

  // ─── MLS lifecycle ─────────────────────────────────────────────
  // Implemented for real by `CryptoBridgeNative` (Android, Plan B);
  // the iOS shim is still stubbed. `CryptoBridgeDart` throws
  // `UnimplementedError` (identity-only).

  /// Boot CoreCrypto with the user's identity seed. Must be called before
  /// any other MLS method. Idempotent — re-calling on an already-init'd
  /// instance is a no-op.
  ///
  /// This only OPENS the store (deferred init). [mlsEnsureClient] must
  /// also run before key packages / groups work.
  Future<void> mlsInit();

  /// Initialize the MLS client identity inside CoreCrypto (survey §4.2
  /// "Step 3" — `ctx.mlsInit(ClientId, ciphersuites, nbKeyPackage)`).
  /// Without this every MLS operation fails with "MLS hasn't been
  /// initialized on this instance".
  ///
  /// [deviceId] is the server-assigned device id — group member leaves
  /// are addressed by device id (removeMember), so the MLS credential
  /// must match. Because the device id only exists once a session does,
  /// callers run this right after account creation, restore, or boot
  /// resume (after [mlsInit]). Idempotent.
  Future<void> mlsEnsureClient(String deviceId);

  /// Open CoreCrypto in read-only mode. Used by background-isolate
  /// handlers (FCM bg handler on Android, NSE on iOS) that need to
  /// decrypt without contending with the foreground app's writer
  /// (spec §11.1 concurrency invariant).
  ///
  /// Idempotent — re-calling on an already-init'd instance is a no-op.
  /// MUST be called before [decrypt] / [decryptAndInspect] from a
  /// background context. The seed is needed to derive the store key
  /// (same HKDF as [mlsInit]); the composite fetches it.
  Future<void> mlsInitReadOnly();

  /// Wipe CoreCrypto's local store. Used by the "Delete account" flow.
  Future<void> mlsWipe();

  /// Whether the local MLS store was purged + rebuilt since the last call,
  /// clearing the flag.
  ///
  /// A rebuilt store destroys the private half of every KeyPackage this device
  /// has published, so the entire published pool is dead and must be REPLACED
  /// server-side (see [ApiClient.publishKeyPackages]'s `reset`). Nothing else
  /// can detect this: the pool still reads as full, so the replenisher's
  /// low-water check never fires, and peers keep drawing dead packages —
  /// making every new conversation undecryptable until all of them are burnt.
  Future<bool> consumeMlsStoreReset();

  /// Generate `count` fresh KeyPackages tied to the current identity.
  /// Each KeyPackage is bytes ready to publish via
  /// `POST /accounts/me/key-packages`.
  Future<List<List<int>>> mintKeyPackages({int count = 100});

  /// Create a new MLS group. `conversationId` doubles as the MLS
  /// group_id (the bridge passes it through to CoreCrypto's `newGroup`
  /// API) — see spec §7.3.
  Future<String> createGroup({required String conversationId});

  /// Add a member identified by `peerKeyPackage` to `groupId`. Returns
  /// an [AddMemberResult] containing Welcome bytes (for the new member's device)
  /// and Commit bytes (to fan out to every existing member's device so their
  /// MLS state advances to the new epoch).
  Future<AddMemberResult> addMember({
    required String groupId,
    required List<int> peerKeyPackage,
  });

  /// Add MANY members to `groupId` in a SINGLE MLS commit. Returns one
  /// [AddMemberResult] whose Welcome covers every added member (each new
  /// member processes the same Welcome and finds its own entry) plus one
  /// Commit. Group creation uses this so every member joins at the SAME
  /// epoch — adding one-at-a-time strands earlier members an epoch behind
  /// and their decrypts fail with MlsUnknownException.
  Future<AddMemberResult> addMembers({
    required String groupId,
    required List<List<int>> peerKeyPackages,
  });

  /// Process a received Welcome. Returns the group_id learned from it
  /// (equal to conversationId per the §7.3 invariant).
  Future<String> processWelcome(List<int> welcomeBytes);

  /// Process a received Commit (membership change, key rotation).
  Future<void> processCommit({
    required String groupId,
    required List<int> commitBytes,
  });

  /// Diagnostic: current MLS epoch number for a group.
  Future<int> currentEpoch(String groupId);

  /// Encrypt application data under the current group epoch's key.
  Future<List<int>> encrypt({
    required String groupId,
    required List<int> plaintext,
  });

  /// Decrypt application data; throws `MlsDecryptException` on
  /// authentication failure.
  Future<List<int>> decrypt({
    required String groupId,
    required List<int> ciphertext,
  });

  /// Decrypts and surfaces structured state. [DecryptMlsResult.plaintext] is
  /// null for pure Commit messages with no application data;
  /// [DecryptMlsResult.selfRemoved] is true when the Commit removed this device
  /// from the group; [DecryptMlsResult.newEpoch] is null when self-removed.
  Future<DecryptMlsResult> decryptAndInspect({
    required String groupId,
    required List<int> ciphertext,
  });

  /// Simultaneous-migration tiebreaker (spec §9.3). Wipes the local group
  /// [localGroupId] from CoreCrypto's state, then processes [foreignWelcome]
  /// to re-init the group from the peer's Welcome. Both operations run in a
  /// single CoreCrypto transaction for atomicity.
  ///
  /// Returns the new group ID (equal to [localGroupId] per the §7.3
  /// invariant, but returned so callers can verify).
  Future<String> replaceGroup({
    required String localGroupId,
    required List<int> foreignWelcome,
  });

  /// Wipe a single group from CoreCrypto's state. Used by `MlsMigrator` to
  /// clean up a half-created group when migration fails between
  /// `createGroup` and the Welcome submit — leaving it behind poisons both
  /// the migration retry (`createGroup` → "already exists") and the peer's
  /// inbound Welcome for the same conversation id.
  Future<void> wipeGroup(String groupId);

  /// Remove a member from [groupId] by device id. Returns the Commit
  /// bytes to fan out to all remaining members + the removed device
  /// (spec §10.6). Used for both admin-initiated removes and self-leave
  /// (callers pass their own deviceId).
  Future<List<int>> removeMember({
    required String groupId,
    required String targetDeviceId,
  });
}

/// Opaque handle to an identity keypair held inside the bridge.
/// Dart never sees the private key bytes.
class IdentityHandle {
  const IdentityHandle({
    required this.id,
    required this.publicKey,
    required this.x25519PublicKey,
  });
  final String id;

  /// Ed25519 public key used for signing the username claim + session
  /// challenges.
  final List<int> publicKey;

  /// X25519 public key used for ECDH on the v1 baseline E2EE layer. Empty
  /// before Plan 13 / 2026-05-09 (legacy identities); freshly-generated
  /// identities always populate it.
  final List<int> x25519PublicKey;
}

/// Test fake — **not cryptographically valid**. Suitable for Riverpod plumbing
/// and compile-checking only. Production uses `CryptoBridgeDart` which signs
/// with real Ed25519 + ECDH-ratcheted AES-GCM. Plan 6 (full) will swap that
/// for CoreCrypto.
class CryptoBridgeStub implements CryptoBridge {
  int _counter = 0;
  IdentityHandle? _current;

  @override
  Future<IdentityHandle> generateIdentity({List<int>? seed}) async {
    _counter++;
    _current = IdentityHandle(
      id: 'stub-id-$_counter',
      publicKey: seed != null
          ? List<int>.from(seed.length >= 32 ? seed.sublist(0, 32) : seed)
          : List<int>.filled(32, _counter),
      x25519PublicKey: List<int>.filled(32, _counter + 100),
    );
    return _current!;
  }

  @override
  Future<IdentityHandle?> currentIdentity() async => _current;

  @override
  Future<List<int>> signWithIdentity(IdentityHandle handle, List<int> payload) async {
    return List<int>.filled(64, 0);
  }

  @override
  Future<List<int>> mintKeyPackage(IdentityHandle handle) async {
    return [for (var i = 0; i < 256; i++) i % 256];
  }

  @override
  Future<ConversationCryptoState> initConversationCrypto({
    required String conversationId,
    required List<int> peerX25519PubKey,
  }) async {
    return ConversationCryptoState(
      conversationId: conversationId,
      sendCounter: 0,
      sendChainKey: List<int>.filled(32, 0),
      recvCounter: 0,
      recvChainKey: List<int>.filled(32, 0),
    );
  }

  @override
  Future<EncryptResult> encryptMessage({
    required ConversationCryptoState state,
    required List<int> plaintext,
  }) async {
    return EncryptResult(
      ciphertext: List<int>.from(plaintext),
      newState: state.copyWith(sendCounter: state.sendCounter + 1),
    );
  }

  @override
  Future<DecryptResult> decryptMessage({
    required ConversationCryptoState state,
    required List<int> ciphertext,
  }) async {
    return DecryptResult(
      plaintext: List<int>.from(ciphertext),
      newState: state.copyWith(recvCounter: state.recvCounter + 1),
    );
  }

  @override
  void clearConversationCrypto(String conversationId) {}

  @override
  Future<void> wipe() async {
    _current = null;
    _counter = 0;
  }

  @override
  Future<List<int>?> rawIdentitySeed() async => List<int>.filled(32, 0);

  @override
  Future<void> mlsInit() async {}

  @override
  Future<void> mlsEnsureClient(String deviceId) async {}

  @override
  Future<void> mlsInitReadOnly() async {}

  @override
  Future<void> mlsWipe() async {}

  @override
  Future<bool> consumeMlsStoreReset() async => false;

  @override
  Future<List<List<int>>> mintKeyPackages({int count = 100}) async =>
      List.generate(count, (i) => List<int>.filled(64, i & 0xff));

  @override
  Future<String> createGroup({required String conversationId}) async => conversationId;

  @override
  Future<AddMemberResult> addMember({
    required String groupId,
    required List<int> peerKeyPackage,
  }) async => AddMemberResult(
        welcome: List<int>.filled(32, 0xAB),
        commit: List<int>.filled(32, 0xCC),
      );

  @override
  Future<AddMemberResult> addMembers({
    required String groupId,
    required List<List<int>> peerKeyPackages,
  }) async => AddMemberResult(
        welcome: List<int>.filled(32, 0xAB),
        commit: List<int>.filled(32, 0xCC),
      );

  @override
  Future<String> processWelcome(List<int> welcomeBytes) async => 'stub-group';

  @override
  Future<void> processCommit({
    required String groupId,
    required List<int> commitBytes,
  }) async {}

  @override
  Future<int> currentEpoch(String groupId) async => 0;

  @override
  Future<List<int>> encrypt({
    required String groupId,
    required List<int> plaintext,
  }) async => List<int>.from(plaintext);

  @override
  Future<List<int>> decrypt({
    required String groupId,
    required List<int> ciphertext,
  }) async => List<int>.from(ciphertext);

  @override
  Future<DecryptMlsResult> decryptAndInspect({
    required String groupId,
    required List<int> ciphertext,
  }) async => DecryptMlsResult(
        plaintext: List<int>.from(ciphertext),
        selfRemoved: false,
        newEpoch: 0,
      );

  @override
  Future<String> replaceGroup({
    required String localGroupId,
    required List<int> foreignWelcome,
  }) async => localGroupId;

  @override
  Future<void> wipeGroup(String groupId) async {}

  @override
  Future<List<int>> removeMember({
    required String groupId,
    required String targetDeviceId,
  }) async => List<int>.filled(32, 0xCD);
}
