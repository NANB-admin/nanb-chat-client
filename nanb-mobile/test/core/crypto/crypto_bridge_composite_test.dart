import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nanb_chat/core/crypto/add_member_result.dart';
import 'package:nanb_chat/core/crypto/conversation_crypto_state.dart';
import 'package:nanb_chat/core/crypto/crypto_bridge.dart';
import 'package:nanb_chat/core/crypto/crypto_bridge_composite.dart';
import 'package:nanb_chat/core/crypto/crypto_bridge_native.dart';
import 'package:nanb_chat/core/crypto/decrypt_mls_result.dart';

class _RecordingIdentity implements CryptoBridge {
  @override
  Future<Set<String>> groupMemberDeviceIds(String groupId) async => const {};

  @override
  Future<bool> consumeMlsStoreReset() async => false;

  final List<String> calls = [];
  List<int>? seedToReturn = List<int>.filled(32, 0);

  @override
  Future<IdentityHandle> generateIdentity({List<int>? seed}) async {
    calls.add('generateIdentity');
    return IdentityHandle(id: 'id', publicKey: const [1], x25519PublicKey: const [2]);
  }
  @override
  Future<IdentityHandle?> currentIdentity() async {
    calls.add('currentIdentity');
    return null;
  }
  @override
  Future<List<int>> signWithIdentity(IdentityHandle handle, List<int> payload) async {
    calls.add('signWithIdentity');
    return [1, 2];
  }
  @override
  Future<List<int>> mintKeyPackage(IdentityHandle handle) async {
    calls.add('mintKeyPackage');
    return [];
  }
  @override
  Future<ConversationCryptoState> initConversationCrypto({
    required String conversationId,
    required List<int> peerX25519PubKey,
  }) async {
    calls.add('initConversationCrypto');
    return ConversationCryptoState(
      conversationId: conversationId, sendCounter: 0, sendChainKey: const [],
      recvCounter: 0, recvChainKey: const []);
  }
  @override
  Future<EncryptResult> encryptMessage({
    required ConversationCryptoState state,
    required List<int> plaintext,
  }) async {
    calls.add('encryptMessage');
    return EncryptResult(ciphertext: plaintext, newState: state);
  }
  @override
  Future<DecryptResult> decryptMessage({
    required ConversationCryptoState state,
    required List<int> ciphertext,
  }) async {
    calls.add('decryptMessage');
    return DecryptResult(plaintext: ciphertext, newState: state);
  }
  @override
  void clearConversationCrypto(String conversationId) {
    calls.add('clearConversationCrypto');
  }
  @override
  Future<void> wipe() async { calls.add('wipe-identity'); }

  @override
  Future<List<int>?> rawIdentitySeed() async {
    calls.add('rawIdentitySeed');
    return seedToReturn;
  }

  // MLS methods — should NEVER be called on this stub
  @override
  Future<void> mlsInit() async => throw 'composite should not route mlsInit here';
  @override
  Future<void> mlsEnsureClient(String deviceId) async {}

  @override
  Future<void> mlsInitReadOnly() async => throw 'composite should not route mlsInitReadOnly here';
  @override
  Future<void> mlsWipe() async => throw 'composite should not route mlsWipe here';
  @override
  Future<List<List<int>>> mintKeyPackages({int count = 100}) async =>
      throw 'composite should not route mintKeyPackages here';
  @override
  Future<String> createGroup({required String conversationId}) async =>
      throw 'composite should not route createGroup here';
  @override
  Future<AddMemberResult> addMembers({
    required String groupId,
    required List<List<int>> peerKeyPackages,
  }) async =>
      AddMemberResult(welcome: const [], commit: const []);

  @override
  Future<AddMemberResult> addMember({
    required String groupId, required List<int> peerKeyPackage}) async =>
      throw 'composite should not route addMember here';
  @override
  Future<String> processWelcome(List<int> w) async =>
      throw 'composite should not route processWelcome here';
  @override
  Future<void> processCommit({
    required String groupId, required List<int> commitBytes}) async =>
      throw 'composite should not route processCommit here';
  @override
  Future<int> currentEpoch(String g) async =>
      throw 'composite should not route currentEpoch here';
  @override
  Future<List<int>> encrypt({
    required String groupId, required List<int> plaintext}) async =>
      throw 'composite should not route encrypt here';
  @override
  Future<List<int>> decrypt({
    required String groupId, required List<int> ciphertext}) async =>
      throw 'composite should not route decrypt here';
  @override
  Future<String> replaceGroup({
    required String localGroupId,
    required List<int> foreignWelcome,
  }) async =>
      throw 'composite should not route replaceGroup here';
  @override
  Future<void> wipeGroup(String groupId) async =>
      throw 'composite should not route wipeGroup here';
  @override
  Future<List<int>> removeMember({
    required String groupId,
    required String targetDeviceId,
  }) async =>
      throw 'composite should not route removeMember here';
  @override
  Future<DecryptMlsResult> decryptAndInspect({
    required String groupId,
    required List<int> ciphertext,
  }) async =>
      throw 'composite should not route decryptAndInspect here';
}

class _RecordingMls implements CryptoBridge {
  @override
  Future<Set<String>> groupMemberDeviceIds(String groupId) async => const {};

  @override
  Future<bool> consumeMlsStoreReset() async => false;

  final List<String> calls = [];

  // Identity methods — should NEVER be called on this stub
  @override
  Future<IdentityHandle> generateIdentity({List<int>? seed}) =>
      throw 'composite should not route generateIdentity here';
  @override
  Future<IdentityHandle?> currentIdentity() =>
      throw 'composite should not route currentIdentity here';
  @override
  Future<List<int>> signWithIdentity(IdentityHandle handle, List<int> payload) =>
      throw 'composite should not route signWithIdentity here';
  @override
  Future<List<int>> mintKeyPackage(IdentityHandle handle) =>
      throw 'composite should not route mintKeyPackage here';
  @override
  Future<ConversationCryptoState> initConversationCrypto({
    required String conversationId, required List<int> peerX25519PubKey}) =>
      throw 'composite should not route initConversationCrypto here';
  @override
  Future<EncryptResult> encryptMessage({
    required ConversationCryptoState state, required List<int> plaintext}) =>
      throw 'composite should not route encryptMessage here';
  @override
  Future<DecryptResult> decryptMessage({
    required ConversationCryptoState state, required List<int> ciphertext}) =>
      throw 'composite should not route decryptMessage here';
  @override
  void clearConversationCrypto(String conversationId) {
    throw 'composite should not route clearConversationCrypto here';
  }
  @override
  Future<List<int>?> rawIdentitySeed() =>
      throw 'composite should not route rawIdentitySeed to mls sub-bridge';

  // MLS methods (the ones this stub claims responsibility for)
  @override
  Future<void> mlsInit() async { calls.add('mlsInit'); }
  @override
  Future<void> mlsEnsureClient(String deviceId) async {}

  @override
  Future<void> mlsInitReadOnly() async { calls.add('mlsInitReadOnly'); }
  @override
  Future<void> mlsWipe() async { calls.add('mlsWipe'); }
  @override
  Future<List<List<int>>> mintKeyPackages({int count = 100}) async {
    calls.add('mintKeyPackages'); return [];
  }
  @override
  Future<String> createGroup({required String conversationId}) async {
    calls.add('createGroup'); return conversationId;
  }
  @override
  Future<AddMemberResult> addMembers({
    required String groupId,
    required List<List<int>> peerKeyPackages,
  }) async =>
      AddMemberResult(welcome: const [], commit: const []);

  @override
  Future<AddMemberResult> addMember({
    required String groupId, required List<int> peerKeyPackage}) async {
    calls.add('addMember');
    return AddMemberResult(welcome: [], commit: []);
  }
  @override
  Future<String> processWelcome(List<int> welcomeBytes) async {
    calls.add('processWelcome'); return 'g';
  }
  @override
  Future<void> processCommit({
    required String groupId, required List<int> commitBytes}) async {
    calls.add('processCommit');
  }
  @override
  Future<int> currentEpoch(String groupId) async {
    calls.add('currentEpoch'); return 0;
  }
  @override
  Future<List<int>> encrypt({
    required String groupId, required List<int> plaintext}) async {
    calls.add('encrypt'); return plaintext;
  }
  @override
  Future<List<int>> decrypt({
    required String groupId, required List<int> ciphertext}) async {
    calls.add('decrypt'); return ciphertext;
  }
  @override
  Future<String> replaceGroup({
    required String localGroupId,
    required List<int> foreignWelcome,
  }) async {
    calls.add('replaceGroup'); return localGroupId;
  }
  @override
  Future<void> wipeGroup(String groupId) async {
    calls.add('wipeGroup');
  }
  @override
  Future<List<int>> removeMember({
    required String groupId,
    required String targetDeviceId,
  }) async {
    calls.add('removeMember'); return [];
  }
  @override
  Future<DecryptMlsResult> decryptAndInspect({
    required String groupId,
    required List<int> ciphertext,
  }) async {
    calls.add('decryptAndInspect');
    return DecryptMlsResult(
      plaintext: List<int>.from(ciphertext),
      selfRemoved: false,
      newEpoch: 0,
    );
  }
  @override
  Future<void> wipe() async { calls.add('wipe-mls'); }
}

/// A CryptoBridgeNative subclass with a mocked channel so the composite's
/// `is CryptoBridgeNative` branch is exercised without a real Flutter engine.
///
/// Decision: subclassing CryptoBridgeNative (rather than creating a new
/// interface) keeps the composite's type-check simple and avoids widening the
/// public surface of CryptoBridgeNative. The mock channel captures the seed
/// bytes for assertion without making a real platform call.
class _RecordingNative extends CryptoBridgeNative {
  _RecordingNative(MethodChannel channel) : super(channel: channel);
  List<int>? receivedSeed;
  List<int>? receivedReadOnlySeed;

  @override
  Future<void> mlsInitWithSeed(List<int> seed) async {
    receivedSeed = List<int>.from(seed);
  }

  @override
  Future<void> mlsInitReadOnlyWithSeed(List<int> seed) async {
    receivedReadOnlySeed = List<int>.from(seed);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('identity ops route to identity sub-bridge', () async {
    final id = _RecordingIdentity();
    final mls = _RecordingMls();
    final c = CryptoBridgeComposite(identity: id, mls: mls);
    await c.generateIdentity();
    await c.currentIdentity();
    expect(id.calls, ['generateIdentity', 'currentIdentity']);
    expect(mls.calls, isEmpty);
  });

  test('mls ops (non-mlsInit) route to mls sub-bridge', () async {
    final id = _RecordingIdentity();
    final mls = _RecordingMls();
    final c = CryptoBridgeComposite(identity: id, mls: mls);
    await c.encrypt(groupId: 'g', plaintext: [1, 2]);
    expect(mls.calls, ['encrypt']);
    expect(id.calls, isEmpty);
  });

  test('legacy ratchet ops route to identity sub-bridge', () async {
    final id = _RecordingIdentity();
    final mls = _RecordingMls();
    final c = CryptoBridgeComposite(identity: id, mls: mls);
    final state = await c.initConversationCrypto(
        conversationId: 'cid', peerX25519PubKey: const [1]);
    await c.encryptMessage(state: state, plaintext: const [1]);
    await c.decryptMessage(state: state, ciphertext: const [1]);
    c.clearConversationCrypto('cid');
    expect(id.calls,
        ['initConversationCrypto', 'encryptMessage', 'decryptMessage', 'clearConversationCrypto']);
    expect(mls.calls, isEmpty);
  });

  test('wipe calls both sub-bridges', () async {
    final id = _RecordingIdentity();
    final mls = _RecordingMls();
    final c = CryptoBridgeComposite(identity: id, mls: mls);
    await c.wipe();
    expect(id.calls, ['wipe-identity']);
    expect(mls.calls, ['mlsWipe']);
  });

  test('mlsInit reads seed from identity and forwards via mlsInitWithSeed', () async {
    final id = _RecordingIdentity()..seedToReturn = List<int>.filled(32, 7);
    final mockChannel = const MethodChannel('test.nanb.crypto');
    final native = _RecordingNative(mockChannel);
    final c = CryptoBridgeComposite(identity: id, mls: native);
    await c.mlsInit();
    expect(id.calls, contains('rawIdentitySeed'));
    expect(native.receivedSeed, List<int>.filled(32, 7));
  });

  test('mlsInit throws StateError when identity has no seed yet', () async {
    final id = _RecordingIdentity()..seedToReturn = null;
    final mls = _RecordingMls();
    final c = CryptoBridgeComposite(identity: id, mls: mls);
    expect(() => c.mlsInit(), throwsA(isA<StateError>()));
  });

  test('mlsInit falls through to mls.mlsInit when mls is not CryptoBridgeNative', () async {
    final id = _RecordingIdentity()..seedToReturn = List<int>.filled(32, 1);
    final mls = _RecordingMls();
    final c = CryptoBridgeComposite(identity: id, mls: mls);
    await c.mlsInit();
    expect(mls.calls, contains('mlsInit'));
  });

  test('mlsInitReadOnly reads seed from identity and forwards via mlsInitReadOnlyWithSeed', () async {
    final id = _RecordingIdentity()..seedToReturn = List<int>.filled(32, 5);
    final mockChannel = const MethodChannel('test.nanb.crypto');
    final native = _RecordingNative(mockChannel);
    final c = CryptoBridgeComposite(identity: id, mls: native);
    await c.mlsInitReadOnly();
    expect(id.calls, contains('rawIdentitySeed'));
    expect(native.receivedReadOnlySeed, List<int>.filled(32, 5));
  });

  test('mlsInitReadOnly throws StateError when identity has no seed yet', () async {
    final id = _RecordingIdentity()..seedToReturn = null;
    final mls = _RecordingMls();
    final c = CryptoBridgeComposite(identity: id, mls: mls);
    expect(() => c.mlsInitReadOnly(), throwsA(isA<StateError>()));
  });

  test('mlsInitReadOnly falls through to mls.mlsInitReadOnly when mls is not CryptoBridgeNative', () async {
    final id = _RecordingIdentity()..seedToReturn = List<int>.filled(32, 1);
    final mls = _RecordingMls();
    final c = CryptoBridgeComposite(identity: id, mls: mls);
    await c.mlsInitReadOnly();
    expect(mls.calls, contains('mlsInitReadOnly'));
  });

  test('rawIdentitySeed delegates to identity sub-bridge', () async {
    final id = _RecordingIdentity()..seedToReturn = List<int>.filled(32, 42);
    final mls = _RecordingMls();
    final c = CryptoBridgeComposite(identity: id, mls: mls);
    final seed = await c.rawIdentitySeed();
    expect(seed, List<int>.filled(32, 42));
    expect(id.calls, contains('rawIdentitySeed'));
  });
}
