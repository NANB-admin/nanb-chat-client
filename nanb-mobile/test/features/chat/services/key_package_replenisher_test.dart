import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/core/crypto/crypto_bridge.dart';
import 'package:nanb_chat/core/network/api_client.dart';
import 'package:nanb_chat/core/secure_storage/secure_storage.dart';
import 'package:nanb_chat/features/chat/services/key_package_replenisher.dart';

class _RecordingApi implements ApiClient {
  _RecordingApi({this.count = 100, this.failPublish = false});

  /// What the server reports as remaining — a rebuilt store leaves this FULL
  /// even though every package in it is dead, which is the whole problem.
  int count;
  bool failPublish;
  final List<({int size, bool reset})> published = [];
  int countCalls = 0;

  @override
  Future<int> keyPackageCount() async {
    countCalls++;
    return count;
  }

  @override
  Future<int> publishKeyPackages(List<List<int>> packages,
      {bool reset = false}) async {
    if (failPublish) throw StateError('publish failed');
    published.add((size: packages.length, reset: reset));
    return packages.length;
  }

  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnimplementedError(i.memberName.toString());
}

class _FakeCrypto extends CryptoBridgeStub {
  _FakeCrypto({this.storeReset = false});

  bool storeReset;
  int consumeCalls = 0;

  @override
  Future<bool> consumeMlsStoreReset() async {
    consumeCalls++;
    // One-shot, exactly like the native flag it stands in for.
    final was = storeReset;
    storeReset = false;
    return was;
  }
}

void main() {
  test('a full pool is left alone', () async {
    final api = _RecordingApi(count: 100);
    await KeyPackageReplenisher(api: api, crypto: _FakeCrypto())
        .replenishIfNeeded();

    expect(api.published, isEmpty);
  });

  test('a pool below the low-water mark is topped up without reset', () async {
    final api = _RecordingApi(count: 9);
    await KeyPackageReplenisher(api: api, crypto: _FakeCrypto())
        .replenishIfNeeded();

    expect(api.published.single.size, equals(50));
    expect(api.published.single.reset, isFalse,
        reason: 'an ordinary top-up must not destroy a healthy pool');
  });

  test('a store reset republishes with reset even though the pool reads full',
      () async {
    final api = _RecordingApi(count: 100);
    await KeyPackageReplenisher(api: api, crypto: _FakeCrypto(storeReset: true))
        .replenishIfNeeded();

    expect(api.published.single.reset, isTrue);
  });

  test('a store reset skips the count check entirely', () async {
    // Quantity is meaningless when the packages are dead, so the replenisher
    // must not gate the repair on it.
    final api = _RecordingApi(count: 100);
    await KeyPackageReplenisher(api: api, crypto: _FakeCrypto(storeReset: true))
        .replenishIfNeeded();

    expect(api.countCalls, equals(0));
  });

  test('a failed reset publish is retried on the next run', () async {
    // The native flag is one-shot: if a failed publish dropped it, the device
    // would sit on a dead pool forever.
    final api = _RecordingApi(count: 100, failPublish: true);
    final crypto = _FakeCrypto(storeReset: true);
    final replenisher = KeyPackageReplenisher(api: api, crypto: crypto);

    await replenisher.replenishIfNeeded();
    expect(api.published, isEmpty);

    api.failPublish = false;
    await replenisher.replenishIfNeeded();

    expect(api.published.single.reset, isTrue);
  });

  test('a reset is not republished again once it has landed', () async {
    final api = _RecordingApi(count: 100);
    final replenisher =
        KeyPackageReplenisher(api: api, crypto: _FakeCrypto(storeReset: true));

    await replenisher.replenishIfNeeded();
    await replenisher.replenishIfNeeded();

    expect(api.published.length, equals(1));
  });

  test('a reset publish interrupted by a process kill is retried next launch',
      () async {
    // The native flag is one-shot AND consumed before the publish, so a kill in
    // between used to lose the reset entirely — the device then sat on a pool of
    // dead packages with nothing left to notice. A fresh replenisher (a new
    // process) sharing the same storage must still publish the replacement.
    final storage = SecureStorageInMemory();
    final api = _RecordingApi(count: 100, failPublish: true);
    await KeyPackageReplenisher(
      api: api,
      crypto: _FakeCrypto(storeReset: true),
      storage: storage,
    ).replenishIfNeeded();
    expect(api.published, isEmpty);

    api.failPublish = false;
    // A NEW instance, with the native one-shot flag already spent.
    await KeyPackageReplenisher(
      api: api,
      crypto: _FakeCrypto(storeReset: false),
      storage: storage,
    ).replenishIfNeeded();

    expect(api.published.single.reset, isTrue);
  });

  test('a landed reset publish clears the persisted marker', () async {
    final storage = SecureStorageInMemory();
    final api = _RecordingApi(count: 100);
    await KeyPackageReplenisher(
      api: api,
      crypto: _FakeCrypto(storeReset: true),
      storage: storage,
    ).replenishIfNeeded();

    // A new process must NOT republish: the marker is gone.
    await KeyPackageReplenisher(
      api: api,
      crypto: _FakeCrypto(storeReset: false),
      storage: storage,
    ).replenishIfNeeded();

    expect(api.published.length, equals(1));
  });
}
