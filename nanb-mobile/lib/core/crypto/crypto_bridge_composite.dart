import 'add_member_result.dart';
import 'conversation_crypto_state.dart';
import 'crypto_bridge.dart';
import 'crypto_bridge_native.dart';
import 'decrypt_mls_result.dart';
import 'mls_seeded_bridge.dart';
import 'sealed_envelope.dart';
import 'unidentified_access.dart';

/// Composite bridge that wires `CryptoBridgeDart` (identity + legacy
/// ratchet) and `CryptoBridgeNative` (MLS) behind a single `CryptoBridge`
/// surface. The composite is what `cryptoBridgeProvider` returns in
/// production.
///
/// Routing:
///   - generateIdentity / signWithIdentity / currentIdentity / mintKeyPackage
///     → identity
///   - initConversationCrypto / encryptMessage / decryptMessage /
///     clearConversationCrypto (Plan 13.1 legacy ratchet)
///     → identity
///   - mlsInit / mlsWipe / mintKeyPackages / createGroup / addMember /
///     processWelcome / processCommit / currentEpoch / encrypt / decrypt
///     → mls
///   - wipe() calls identity.wipe() AND mls.mlsWipe() (per spec §8.4
///     account-deletion semantics: both stores must be cleared).
class CryptoBridgeComposite
    implements CryptoBridge, SealOpener, UnidentifiedAccessProvider {
  CryptoBridgeComposite({required this.identity, required this.mls});

  final CryptoBridge identity;
  final CryptoBridge mls;

  /// Sealed-sender (Phase 1): opening uses this device's X25519 private key,
  /// which lives in the identity (Dart) bridge — delegate there.
  @override
  Future<List<int>> openSealed(List<int> sealed) =>
      (identity as SealOpener).openSealed(sealed);

  /// Sealed-sender Phase 2: the UAK derives from the X25519 identity in the
  /// identity (Dart) bridge — delegate there.
  @override
  Future<List<int>> unidentifiedAccessKey() =>
      (identity as UnidentifiedAccessProvider).unidentifiedAccessKey();

  @override
  Future<List<int>> unidentifiedAccessCommitment() =>
      (identity as UnidentifiedAccessProvider).unidentifiedAccessCommitment();

  @override
  Future<IdentityHandle> generateIdentity({List<int>? seed}) =>
      identity.generateIdentity(seed: seed);

  @override
  Future<IdentityHandle?> currentIdentity() => identity.currentIdentity();

  @override
  Future<List<int>> signWithIdentity(IdentityHandle handle, List<int> payload) =>
      identity.signWithIdentity(handle, payload);

  @override
  Future<List<int>> mintKeyPackage(IdentityHandle handle) =>
      identity.mintKeyPackage(handle);

  @override
  Future<ConversationCryptoState> initConversationCrypto({
    required String conversationId,
    required List<int> peerX25519PubKey,
  }) =>
      identity.initConversationCrypto(
        conversationId: conversationId, peerX25519PubKey: peerX25519PubKey);

  @override
  Future<EncryptResult> encryptMessage({
    required ConversationCryptoState state,
    required List<int> plaintext,
  }) =>
      identity.encryptMessage(state: state, plaintext: plaintext);

  @override
  Future<DecryptResult> decryptMessage({
    required ConversationCryptoState state,
    required List<int> ciphertext,
  }) =>
      identity.decryptMessage(state: state, ciphertext: ciphertext);

  @override
  void clearConversationCrypto(String conversationId) =>
      identity.clearConversationCrypto(conversationId);

  @override
  Future<List<int>?> rawIdentitySeed() => identity.rawIdentitySeed();

  @override
  Future<void> mlsInit() async {
    final seed = await identity.rawIdentitySeed();
    if (seed == null) {
      throw StateError(
        'mlsInit called before identity is generated — '
        'CryptoBridgeDart.generateIdentity() must run first.',
      );
    }
    final bridge = mls;
    if (bridge is CryptoBridgeNative) {
      await bridge.mlsInitWithSeed(seed);
    } else if (bridge is MlsSeededBridge) {
      // Browser CoreCrypto: same seed-keyed store, opened via JS interop.
      await (bridge as MlsSeededBridge).mlsInitWithSeed(seed);
    } else {
      // Tests may inject a non-native MLS sub-bridge that accepts a no-arg mlsInit.
      await mls.mlsInit();
    }
  }

  @override
  Future<void> mlsInitReadOnly() async {
    final seed = await identity.rawIdentitySeed();
    if (seed == null) {
      throw StateError(
        'mlsInitReadOnly called before identity is generated.',
      );
    }
    final bridge = mls;
    if (bridge is CryptoBridgeNative) {
      await bridge.mlsInitReadOnlyWithSeed(seed);
    } else if (bridge is MlsSeededBridge) {
      await (bridge as MlsSeededBridge).mlsInitReadOnlyWithSeed(seed);
    } else {
      await mls.mlsInitReadOnly();
    }
  }

  @override
  Future<void> mlsEnsureClient(String deviceId) =>
      mls.mlsEnsureClient(deviceId);

  @override
  Future<void> mlsWipe() => mls.mlsWipe();

  @override
  Future<bool> consumeMlsStoreReset() => mls.consumeMlsStoreReset();

  @override
  Future<List<List<int>>> mintKeyPackages({int count = 100}) =>
      mls.mintKeyPackages(count: count);

  @override
  Future<String> createGroup({required String conversationId}) =>
      mls.createGroup(conversationId: conversationId);

  @override
  Future<AddMemberResult> addMember({
    required String groupId,
    required List<int> peerKeyPackage,
  }) =>
      mls.addMember(groupId: groupId, peerKeyPackage: peerKeyPackage);

  @override
  Future<AddMemberResult> addMembers({
    required String groupId,
    required List<List<int>> peerKeyPackages,
  }) =>
      mls.addMembers(groupId: groupId, peerKeyPackages: peerKeyPackages);

  @override
  Future<String> processWelcome(List<int> welcomeBytes) =>
      mls.processWelcome(welcomeBytes);

  @override
  Future<void> processCommit({
    required String groupId,
    required List<int> commitBytes,
  }) =>
      mls.processCommit(groupId: groupId, commitBytes: commitBytes);

  @override
  Future<int> currentEpoch(String groupId) => mls.currentEpoch(groupId);

  @override
  Future<Set<String>> groupMemberDeviceIds(String groupId) =>
      mls.groupMemberDeviceIds(groupId);

  @override
  Future<List<int>> encrypt({
    required String groupId,
    required List<int> plaintext,
  }) =>
      mls.encrypt(groupId: groupId, plaintext: plaintext);

  @override
  Future<List<int>> decrypt({
    required String groupId,
    required List<int> ciphertext,
  }) =>
      mls.decrypt(groupId: groupId, ciphertext: ciphertext);

  @override
  Future<DecryptMlsResult> decryptAndInspect({
    required String groupId,
    required List<int> ciphertext,
  }) =>
      mls.decryptAndInspect(groupId: groupId, ciphertext: ciphertext);

  @override
  Future<String> replaceGroup({
    required String localGroupId,
    required List<int> foreignWelcome,
  }) =>
      mls.replaceGroup(localGroupId: localGroupId, foreignWelcome: foreignWelcome);

  @override
  Future<void> wipeGroup(String groupId) => mls.wipeGroup(groupId);

  @override
  Future<List<int>> removeMember({
    required String groupId,
    required String targetDeviceId,
  }) =>
      mls.removeMember(groupId: groupId, targetDeviceId: targetDeviceId);

  @override
  Future<void> wipe() async {
    await identity.wipe();
    await mls.mlsWipe();
  }
}
