import 'package:flutter/services.dart';

import 'add_member_result.dart';
import 'conversation_crypto_state.dart';
import 'crypto_bridge.dart';
import 'decrypt_mls_result.dart';
import 'mls_exceptions.dart';

/// Native CoreCrypto MLS implementation. All non-identity methods route
/// through `MethodChannel("nanb.crypto")` to the Kotlin/Swift shim that
/// owns CoreCrypto state.
///
/// **Plan B (current, Android):** the channel handlers
/// (`NanbCryptoChannel.kt`) make real CoreCrypto calls — group create,
/// add member, encrypt/decrypt, Welcome processing — against the
/// `MLS_128_DHKEMX25519_AES128GCM_SHA256_ED25519` ciphersuite, with
/// state in an encrypted SQLite store keyed from the identity seed.
/// The iOS shim (`NanbCryptoChannel.swift`) is still Plan A stubs:
/// every method returns `mls_not_implemented` except mlsInit/mlsWipe,
/// so iOS conversations stay on the legacy ratchet.
///
/// Identity methods (`generateIdentity`, `signWithIdentity`,
/// `currentIdentity`, plus the legacy ratchet methods) are NOT
/// implemented here — `CryptoBridgeComposite` routes them to
/// `CryptoBridgeDart` instead. Callers should always use the composite,
/// not this class directly.
class CryptoBridgeNative implements CryptoBridge {
  CryptoBridgeNative({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('nanb.crypto');

  final MethodChannel _channel;

  // --- Identity methods (NOT supported here — use the composite) ---
  @override
  Future<IdentityHandle> generateIdentity({List<int>? seed}) =>
      throw UnsupportedError(
          'CryptoBridgeNative does not handle identity. Use CryptoBridgeComposite.');

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
      'CryptoBridgeNative.wipe() is not the right entry point. '
      'Use CryptoBridgeComposite.wipe() (which calls both identity.wipe() '
      'and mls.mlsWipe()) or call mlsWipe() directly for MLS-only state.',
    );
  }

  @override
  Future<List<int>?> rawIdentitySeed() => throw UnsupportedError(
        'CryptoBridgeNative does not own the identity seed. '
        'Use CryptoBridgeDart.rawIdentitySeed() via the composite.',
      );

  // --- MLS lifecycle ---

  /// Channel-side mlsInit takes a 32-byte seed arg. The composite reads the
  /// seed from CryptoBridgeDart and forwards it here.
  ///
  /// Direct callers must NOT call [mlsInit] — use
  /// [CryptoBridgeComposite.mlsInit] which loads the seed automatically.
  Future<void> mlsInitWithSeed(List<int> seed) =>
      _invoke<void>('mlsInit', {'seed': Uint8List.fromList(seed)});

  @override
  Future<void> mlsInit() => throw UnsupportedError(
        'Call mlsInitWithSeed via the composite instead — CryptoBridgeNative '
        "doesn't own the identity seed.",
      );

  /// Channel-side mlsInitReadOnly takes a 32-byte seed arg. The composite reads the
  /// seed from CryptoBridgeDart and forwards it here.
  ///
  /// Direct callers must NOT call [mlsInitReadOnly] — use
  /// [CryptoBridgeComposite.mlsInitReadOnly] which loads the seed automatically.
  Future<void> mlsInitReadOnlyWithSeed(List<int> seed) =>
      _invoke<void>('mlsInitReadOnly', {'seed': Uint8List.fromList(seed)});

  @override
  Future<void> mlsInitReadOnly() => throw UnsupportedError(
        'Call mlsInitReadOnlyWithSeed via the composite instead — CryptoBridgeNative '
        "doesn't own the identity seed.",
      );

  @override
  Future<void> mlsEnsureClient(String deviceId) =>
      _invoke<void>('mlsClientInit', {'clientId': deviceId});

  @override
  Future<void> mlsWipe() => _invoke<void>('mlsWipe', null);

  @override
  Future<bool> consumeMlsStoreReset() async =>
      await _invoke<bool>('mlsConsumeStoreReset', null) ?? false;

  @override
  Future<List<List<int>>> mintKeyPackages({int count = 100}) async {
    final raw = await _invoke<List<dynamic>>('mintKeyPackages', {'count': count});
    return raw!
        .map((b) => List<int>.from(b as Uint8List))
        .toList(growable: false);
  }

  @override
  Future<String> createGroup({required String conversationId}) async {
    final res = await _invoke<String>('createGroup', {
      'conversationId': conversationId,
    });
    return res!;
  }

  @override
  Future<AddMemberResult> addMember({
    required String groupId,
    required List<int> peerKeyPackage,
  }) async {
    final raw = await _invoke<Map<dynamic, dynamic>>('addMember', {
      'groupId': groupId,
      'peerKeyPackage': Uint8List.fromList(peerKeyPackage),
    });
    final m = raw!;
    return AddMemberResult(
      welcome: List<int>.from(m['welcome'] as Uint8List),
      commit: List<int>.from(m['commit'] as Uint8List),
    );
  }

  @override
  Future<AddMemberResult> addMembers({
    required String groupId,
    required List<List<int>> peerKeyPackages,
  }) async {
    final raw = await _invoke<Map<dynamic, dynamic>>('addMembers', {
      'groupId': groupId,
      'peerKeyPackages': [
        for (final kp in peerKeyPackages) Uint8List.fromList(kp),
      ],
    });
    final m = raw!;
    return AddMemberResult(
      welcome: List<int>.from(m['welcome'] as Uint8List),
      commit: List<int>.from(m['commit'] as Uint8List),
    );
  }

  @override
  Future<String> processWelcome(List<int> welcomeBytes) async {
    final res = await _invoke<String>('processWelcome', {
      'welcomeBytes': Uint8List.fromList(welcomeBytes),
    });
    return res!;
  }

  @override
  Future<void> processCommit({
    required String groupId,
    required List<int> commitBytes,
  }) =>
      _invoke<void>('processCommit', {
        'groupId': groupId,
        'commitBytes': Uint8List.fromList(commitBytes),
      });

  @override
  Future<int> currentEpoch(String groupId) async {
    final res = await _invoke<int>('currentEpoch', {'groupId': groupId});
    return res!;
  }

  @override
  Future<Set<String>> groupMemberDeviceIds(String groupId) async {
    final res =
        await _invoke<List<Object?>>('groupMembers', {'groupId': groupId});
    return res!.cast<String>().toSet();
  }

  @override
  Future<List<int>> encrypt({
    required String groupId,
    required List<int> plaintext,
  }) async {
    final raw = await _invoke<Uint8List>('encrypt', {
      'groupId': groupId,
      'plaintext': Uint8List.fromList(plaintext),
    });
    return List<int>.from(raw!);
  }

  @override
  Future<DecryptMlsResult> decryptAndInspect({
    required String groupId,
    required List<int> ciphertext,
  }) async {
    final raw = await _invoke<Map<dynamic, dynamic>>('decryptAndInspect', {
      'groupId': groupId,
      'ciphertext': Uint8List.fromList(ciphertext),
    });
    final m = raw!;
    final ptRaw = m['plaintext'];
    final List<int>? plaintext =
        ptRaw == null ? null : List<int>.from(ptRaw as Uint8List);
    return DecryptMlsResult(
      plaintext: plaintext,
      selfRemoved: m['selfRemoved'] as bool,
      newEpoch: m['newEpoch'] as int?,
      senderClientId: m['senderClientId'] as String?,
    );
  }

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
  }) async {
    final res = await _invoke<String>('replaceGroup', {
      'localGroupId': localGroupId,
      'foreignWelcome': Uint8List.fromList(foreignWelcome),
    });
    return res!;
  }

  @override
  Future<void> wipeGroup(String groupId) async {
    await _invoke<void>('wipeGroup', {'groupId': groupId});
  }

  @override
  Future<List<int>> removeMember({
    required String groupId,
    required String targetDeviceId,
  }) async {
    final raw = await _invoke<Uint8List>('removeMember', {
      'groupId': groupId,
      'targetDeviceId': targetDeviceId,
    });
    return List<int>.from(raw!);
  }

  /// Channel-call wrapper that maps PlatformException to typed MlsException.
  Future<T?> _invoke<T>(String method, Map<String, dynamic>? args) async {
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on PlatformException catch (e) {
      throw _mapException(e);
    }
  }

  MlsException _mapException(PlatformException e) {
    final msg = e.message ?? '';
    switch (e.code) {
      case 'mls_not_implemented':
        return MlsNotImplementedException(msg);
      case 'mls_unknown_group':
        return MlsUnknownGroupException(msg);
      case 'mls_decrypt_failed':
        return MlsDecryptException(msg);
      case 'mls_io':
        return MlsIoException(msg);
      case 'mls_invalid_argument':
        return MlsArgumentException(msg);
      case 'mls_orphan_welcome':
        return MlsOrphanWelcomeException(msg);
      default:
        return MlsUnknownException(e.code, msg);
    }
  }
}
