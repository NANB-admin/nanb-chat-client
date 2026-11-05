import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nanb_chat/core/crypto/add_member_result.dart';
import 'package:nanb_chat/core/crypto/crypto_bridge_native.dart';
import 'package:nanb_chat/core/crypto/mls_exceptions.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('nanb.crypto');
  final messenger = TestWidgetsFlutterBinding.instance.defaultBinaryMessenger;

  setUp(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('mlsInit throws UnsupportedError — composite is the only caller', () async {
    final bridge = CryptoBridgeNative();
    expect(() => bridge.mlsInit(), throwsA(isA<UnsupportedError>()));
  });

  test('mlsInitReadOnly throws UnsupportedError — composite is the only caller', () async {
    final bridge = CryptoBridgeNative();
    expect(() => bridge.mlsInitReadOnly(), throwsA(isA<UnsupportedError>()));
  });

  test('mlsInitReadOnlyWithSeed passes seed to mlsInitReadOnly channel call', () async {
    String? gotMethod;
    Uint8List? gotSeed;
    messenger.setMockMethodCallHandler(channel, (call) async {
      gotMethod = call.method;
      gotSeed = (call.arguments as Map)['seed'] as Uint8List?;
      return null;
    });
    final bridge = CryptoBridgeNative();
    await bridge.mlsInitReadOnlyWithSeed([7, 8, 9]);
    expect(gotMethod, 'mlsInitReadOnly');
    expect(gotSeed, [7, 8, 9]);
  });

  test('mlsInitWithSeed passes seed bytes to channel as mlsInit', () async {
    String? gotMethod;
    Uint8List? gotSeed;
    messenger.setMockMethodCallHandler(channel, (call) async {
      gotMethod = call.method;
      final args = call.arguments as Map;
      gotSeed = args['seed'] as Uint8List?;
      return null;
    });
    final bridge = CryptoBridgeNative();
    await bridge.mlsInitWithSeed([1, 2, 3, 4]);
    expect(gotMethod, 'mlsInit');
    expect(gotSeed, [1, 2, 3, 4]);
  });

  test('mlsWipe invokes channel', () async {
    bool called = false;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'mlsWipe') called = true;
      return null;
    });
    final bridge = CryptoBridgeNative();
    await bridge.mlsWipe();
    expect(called, isTrue);
  });

  test('mintKeyPackages returns native list', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'mintKeyPackages');
      expect((call.arguments as Map)['count'], 3);
      return [
        Uint8List.fromList([1, 2, 3]),
        Uint8List.fromList([4, 5, 6]),
        Uint8List.fromList([7, 8, 9]),
      ];
    });
    final bridge = CryptoBridgeNative();
    final kps = await bridge.mintKeyPackages(count: 3);
    expect(kps.length, 3);
    expect(kps[0], [1, 2, 3]);
  });

  test('createGroup returns groupId from channel', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'createGroup');
      expect((call.arguments as Map)['conversationId'], 'group:abc');
      return 'group:abc';
    });
    final bridge = CryptoBridgeNative();
    final id = await bridge.createGroup(conversationId: 'group:abc');
    expect(id, 'group:abc');
  });

  test('encrypt round-trips bytes through the channel', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'encrypt');
      final args = call.arguments as Map;
      expect(args['groupId'], 'group:abc');
      final pt = args['plaintext'] as Uint8List;
      return Uint8List.fromList(pt.reversed.toList());
    });
    final bridge = CryptoBridgeNative();
    final ct = await bridge.encrypt(
      groupId: 'group:abc', plaintext: [1, 2, 3]);
    expect(ct, [3, 2, 1]);
  });

  test('PlatformException with mls_not_implemented becomes MlsNotImplementedException', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(
          code: 'mls_not_implemented',
          message: 'plan A stub — wire real impl in plan B');
    });
    final bridge = CryptoBridgeNative();
    expect(
      () => bridge.encrypt(groupId: 'g', plaintext: [1]),
      throwsA(isA<MlsNotImplementedException>()),
    );
  });

  test('PlatformException with mls_decrypt_failed becomes MlsDecryptException', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(
          code: 'mls_decrypt_failed', message: 'AEAD failed');
    });
    final bridge = CryptoBridgeNative();
    expect(
      () => bridge.decrypt(groupId: 'g', ciphertext: [1]),
      throwsA(isA<MlsDecryptException>()),
    );
  });

  test('PlatformException with unknown code becomes MlsUnknownException', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(code: 'wat', message: 'gibberish');
    });
    final bridge = CryptoBridgeNative();
    try {
      await bridge.encrypt(groupId: 'g', plaintext: [1]);
      fail('expected MlsUnknownException');
    } on MlsUnknownException catch (e) {
      expect(e.code, 'wat');
    }
  });

  test('removeMember sends removeMember channel call with groupId + targetDeviceId', () async {
    String? gotMethod;
    Map? gotArgs;
    messenger.setMockMethodCallHandler(channel, (call) async {
      gotMethod = call.method;
      gotArgs = call.arguments as Map?;
      return Uint8List.fromList([1, 2, 3]);
    });
    final bridge = CryptoBridgeNative();
    final commit = await bridge.removeMember(
      groupId: 'group:g1',
      targetDeviceId: 'dev-x',
    );
    expect(gotMethod, 'removeMember');
    expect(gotArgs!['groupId'], 'group:g1');
    expect(gotArgs!['targetDeviceId'], 'dev-x');
    expect(commit, [1, 2, 3]);
  });

  test('decryptAndInspect parses plaintext + selfRemoved + newEpoch', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'decryptAndInspect');
      return {
        'plaintext': Uint8List.fromList([42, 43]),
        'selfRemoved': true,
        'newEpoch': 8,
      };
    });
    final out = await CryptoBridgeNative().decryptAndInspect(
      groupId: 'g1',
      ciphertext: const [9, 9],
    );
    expect(out.plaintext, [42, 43]);
    expect(out.selfRemoved, true);
    expect(out.newEpoch, 8);
  });

  test('decryptAndInspect handles null plaintext for commits', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      return {
        'plaintext': null,
        'selfRemoved': false,
        'newEpoch': 3,
      };
    });
    final out = await CryptoBridgeNative().decryptAndInspect(
      groupId: 'g1',
      ciphertext: const [0],
    );
    expect(out.plaintext, isNull);
  });

  test('decrypt unwraps decryptAndInspect plaintext', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'decryptAndInspect');
      return {
        'plaintext': Uint8List.fromList([7, 7]),
        'selfRemoved': false,
        'newEpoch': 1,
      };
    });
    final pt = await CryptoBridgeNative().decrypt(
      groupId: 'g1',
      ciphertext: const [0],
    );
    expect(pt, [7, 7]);
  });

  test('decrypt throws StateError when plaintext is null', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      return {
        'plaintext': null,
        'selfRemoved': true,
        'newEpoch': null,
      };
    });
    expect(
      () => CryptoBridgeNative().decrypt(groupId: 'g1', ciphertext: const [0]),
      throwsA(isA<StateError>()),
    );
  });

  test('addMember returns AddMemberResult with welcome + commit from channel Map', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'addMember');
      final args = call.arguments as Map;
      expect(args['groupId'], 'group:g1');
      return {
        'welcome': Uint8List.fromList([1, 2, 3]),
        'commit': Uint8List.fromList([4, 5, 6]),
      };
    });
    final bridge = CryptoBridgeNative();
    final result = await bridge.addMember(
      groupId: 'group:g1',
      peerKeyPackage: const [9, 9],
    );
    expect(result, isA<AddMemberResult>());
    expect(result.welcome, [1, 2, 3]);
    expect(result.commit, [4, 5, 6]);
  });
}
