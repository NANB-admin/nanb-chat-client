import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/core/crypto/mls_store_key.dart';

String _hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

void main() {
  final seed = List<int>.generate(32, (i) => i);

  test('deriveKey matches the HKDF-SHA256 value the native store uses', () async {
    // Reference computed independently with Python hmac:
    // HKDF(ikm=seed, salt=empty, info="nanb-corecrypto-store-v1", L=32).
    final key = await MlsStoreKey.deriveKey(seed);
    expect(_hex(key),
        '3e405886cfa7aa416e43abe98c93b5e9d59d32a30ee1509bebb3bf8a748e796a');
  });

  test('deriveKey is deterministic', () async {
    expect(await MlsStoreKey.deriveKey(seed), await MlsStoreKey.deriveKey(seed));
  });

  test('deriveKey differs for a different seed', () async {
    final other = List<int>.generate(32, (i) => 31 - i);
    expect(await MlsStoreKey.deriveKey(seed),
        isNot(await MlsStoreKey.deriveKey(other)));
  });

  test('databaseName is prefix plus first 8 bytes of SHA-256(seed)', () async {
    expect(await MlsStoreKey.databaseName(seed), 'nanb-mls-630dcd2966c43366');
  });

  test('databaseName differs for a different seed', () async {
    final other = List<int>.generate(32, (i) => 31 - i);
    expect(await MlsStoreKey.databaseName(seed),
        isNot(await MlsStoreKey.databaseName(other)));
  });

  test('databaseName does not contain the store key', () async {
    final name = await MlsStoreKey.databaseName(seed);
    final key = _hex(await MlsStoreKey.deriveKey(seed));
    expect(name.contains(key.substring(0, 16)), isFalse);
  });
}
