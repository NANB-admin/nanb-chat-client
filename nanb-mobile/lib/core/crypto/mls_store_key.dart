import 'package:cryptography/cryptography.dart';

/// Derives the browser CoreCrypto store parameters from the identity seed.
///
/// The key derivation is identical to the native store
/// (`MlsClientHolder.deriveStoreKey`): HKDF-SHA256, empty salt, info
/// `nanb-corecrypto-store-v1`, 32 bytes — so the same seed opens the same store.
class MlsStoreKey {
  const MlsStoreKey._();

  static const String hkdfInfo = 'nanb-corecrypto-store-v1';
  static const String databasePrefix = 'nanb-mls-';

  static Future<List<int>> deriveKey(List<int> seed) async {
    final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
    final key = await hkdf.deriveKey(
      secretKey: SecretKey(seed),
      nonce: const <int>[],
      info: hkdfInfo.codeUnits,
    );
    return key.extractBytes();
  }

  /// A stable per-account IndexedDB name. It is the first 8 bytes of
  /// SHA-256(seed) in hex, so it never reveals the seed itself.
  static Future<String> databaseName(List<int> seed) async {
    final hash = await Sha256().hash(seed);
    final hex = hash.bytes
        .take(8)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    return '$databasePrefix$hex';
  }
}
