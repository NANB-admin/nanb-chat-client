import 'dart:js_interop';
import 'dart:typed_data';

import 'add_member_result.dart';
import 'conversation_crypto_state.dart';
import 'crypto_bridge.dart';
import 'decrypt_mls_result.dart';
import 'mls_error_mapper.dart';
import 'mls_exceptions.dart';
import 'mls_seeded_bridge.dart';
import 'mls_store_key.dart';
import 'models/nanb_add_member_result_js.dart';
import 'nanb_mls_js.dart';

/// Browser MLS implementation: Wire CoreCrypto compiled to WASM
/// (`web/nanb_mls.js`, source in tool/web_mls) behind the same surface as
/// `CryptoBridgeNative`. State lives in IndexedDB.
///
/// Like the native bridge it does NOT handle identity or the legacy ratchet —
/// `CryptoBridgeComposite` routes those to `CryptoBridgeDart`. The composite
/// must open the store through [MlsSeededBridge] (the no-arg [mlsInit] throws,
/// exactly as on native).
class CryptoBridgeWeb implements CryptoBridge, MlsSeededBridge {
  CryptoBridgeWeb();

  // --- Identity methods (NOT supported here — use the composite) ---
  @override
  Future<IdentityHandle> generateIdentity({List<int>? seed}) =>
      throw UnsupportedError(
          'CryptoBridgeWeb does not handle identity. Use CryptoBridgeComposite.');

  @override
  Future<IdentityHandle?> currentIdentity() =>
      throw UnsupportedError('See CryptoBridgeComposite.');

  @override
  Future<List<int>> signWithIdentity(IdentityHandle handle, List<int> payload) =>
      throw UnsupportedError('See CryptoBridgeComposite.');

  @override
  Future<List<int>> mintKeyPackage(IdentityHandle handle) =>
      throw UnsupportedError(
          'Use mintKeyPackages(count:) for the MLS batch surface.');

  @override
  Future<ConversationCryptoState> initConversationCrypto({
    required String conversationId,
    required List<int> peerX25519PubKey,
  }) =>
      throw UnsupportedError(
          'Legacy ratchet — handled by CryptoBridgeDart through the composite.');

  @override
  Future<EncryptResult> encryptMessage({
    required ConversationCryptoState state,
    required List<int> plaintext,
  }) =>
      throw UnsupportedError('Legacy ratchet — see CryptoBridgeDart.');

  @override
  Future<DecryptResult> decryptMessage({
    required ConversationCryptoState state,
    required List<int> ciphertext,
  }) =>
      throw UnsupportedError('Legacy ratchet — see CryptoBridgeDart.');

  @override
  void clearConversationCrypto(String conversationId) {
    // No-op — legacy ratchet skipped-key cache lives in CryptoBridgeDart.
  }

  @override
  Future<void> wipe() async {
    throw UnsupportedError(
      'CryptoBridgeWeb.wipe() is not the right entry point. '
      'Use CryptoBridgeComposite.wipe() (which calls both identity.wipe() '
      'and mls.mlsWipe()) or call mlsWipe() directly for MLS-only state.',
    );
  }

  @override
  Future<List<int>?> rawIdentitySeed() => throw UnsupportedError(
        'CryptoBridgeWeb does not own the identity seed. '
        'Use CryptoBridgeDart.rawIdentitySeed() via the composite.',
      );

  // --- MLS lifecycle ---

  @override
  Future<void> mlsInitWithSeed(List<int> seed) async {
    if (seed.length != 32) {
      throw MlsArgumentException('seed must be 32 bytes, got ${seed.length}');
    }
    final key = await MlsStoreKey.deriveKey(seed);
    final name = await MlsStoreKey.databaseName(seed);
    await _call((api) => api.open(name, Uint8List.fromList(key).toJS).toDart);
  }

  /// The browser has no background isolate; read-only init is a normal open.
  @override
  Future<void> mlsInitReadOnlyWithSeed(List<int> seed) => mlsInitWithSeed(seed);

  @override
  Future<void> mlsInit() => throw UnsupportedError(
        'Call mlsInitWithSeed via the composite instead — CryptoBridgeWeb '
        "doesn't own the identity seed.",
      );

  @override
  Future<void> mlsInitReadOnly() => throw UnsupportedError(
        'Call mlsInitReadOnlyWithSeed via the composite instead — '
        "CryptoBridgeWeb doesn't own the identity seed.",
      );

  @override
  Future<void> mlsEnsureClient(String deviceId) =>
      _call((api) => api.ensureClient(deviceId).toDart);

  @override
  Future<void> mlsWipe() => _call((api) => api.wipe().toDart);

  @override
  Future<bool> consumeMlsStoreReset() =>
      _call((api) async => (await api.consumeStoreReset().toDart).toDart);

  @override
  Future<List<List<int>>> mintKeyPackages({int count = 100}) =>
      _call((api) async {
        final raw = await api.mintKeyPackages(count).toDart;
        return [for (final kp in raw.toDart) kp.toDart];
      });

  @override
  Future<String> createGroup({required String conversationId}) =>
      _call((api) async =>
          (await api.createGroup(conversationId).toDart).toDart);

  @override
  Future<AddMemberResult> addMember({
    required String groupId,
    required List<int> peerKeyPackage,
  }) =>
      _call((api) async => _toAddMemberResult(await api
          .addMember(groupId, Uint8List.fromList(peerKeyPackage).toJS)
          .toDart));

  @override
  Future<AddMemberResult> addMembers({
    required String groupId,
    required List<List<int>> peerKeyPackages,
  }) =>
      _call((api) async {
        final kps = <JSUint8Array>[
          for (final kp in peerKeyPackages) Uint8List.fromList(kp).toJS,
        ].toJS;
        return _toAddMemberResult(await api.addMembers(groupId, kps).toDart);
      });

  @override
  Future<String> processWelcome(List<int> welcomeBytes) =>
      _call((api) async => (await api
              .processWelcome(Uint8List.fromList(welcomeBytes).toJS)
              .toDart)
          .toDart);

  @override
  Future<void> processCommit({
    required String groupId,
    required List<int> commitBytes,
  }) =>
      _call((api) =>
          api.processCommit(groupId, Uint8List.fromList(commitBytes).toJS).toDart);

  @override
  Future<int> currentEpoch(String groupId) => _call(
      (api) async => (await api.currentEpoch(groupId).toDart).toDartInt);

  @override
  Future<List<int>> encrypt({
    required String groupId,
    required List<int> plaintext,
  }) =>
      _call((api) async => (await api
              .encrypt(groupId, Uint8List.fromList(plaintext).toJS)
              .toDart)
          .toDart);

  @override
  Future<DecryptMlsResult> decryptAndInspect({
    required String groupId,
    required List<int> ciphertext,
  }) =>
      _call((api) async {
        final r = await api
            .decryptAndInspect(groupId, Uint8List.fromList(ciphertext).toJS)
            .toDart;
        return DecryptMlsResult(
          plaintext: r.plaintext?.toDart,
          selfRemoved: r.selfRemoved,
          newEpoch: r.newEpoch,
          senderClientId: r.senderClientId,
        );
      });

  @override
  Future<List<int>> decrypt({
    required String groupId,
    required List<int> ciphertext,
  }) async {
    final r = await decryptAndInspect(groupId: groupId, ciphertext: ciphertext);
    if (r.plaintext == null) {
      throw StateError('decrypt called on message with no application payload');
    }
    return r.plaintext!;
  }

  @override
  Future<String> replaceGroup({
    required String localGroupId,
    required List<int> foreignWelcome,
  }) =>
      _call((api) async => (await api
              .replaceGroup(
                  localGroupId, Uint8List.fromList(foreignWelcome).toJS)
              .toDart)
          .toDart);

  @override
  Future<void> wipeGroup(String groupId) =>
      _call((api) => api.wipeGroup(groupId).toDart);

  @override
  Future<List<int>> removeMember({
    required String groupId,
    required String targetDeviceId,
  }) =>
      _call((api) async =>
          (await api.removeMember(groupId, targetDeviceId).toDart).toDart);

  AddMemberResult _toAddMemberResult(NanbAddMemberResultJs r) =>
      AddMemberResult(welcome: r.welcome.toDart, commit: r.commit.toDart);

  /// Runs [body] against `window.nanbMls`, mapping any JS rejection to the
  /// typed MlsException the native bridge would have thrown.
  Future<T> _call<T>(Future<T> Function(NanbMlsJs api) body) async {
    final api = await awaitNanbMls();
    try {
      return await body(api);
    } catch (e) {
      throw MlsErrorMapper.fromErrorText(e.toString());
    }
  }
}
