/// Abstraction over Keychain (iOS) / Keystore (Android). Tests inject a fake
/// in-memory map; production wires `flutter_secure_storage`.
abstract class SecureStorage {
  Future<String?> getString(String key);
  Future<void> putString(String key, String value);
  Future<void> delete(String key);
  Future<void> clear();
}

/// In-memory implementation usable in unit tests.
class SecureStorageInMemory implements SecureStorage {
  final Map<String, String> _data = {};

  @override
  Future<String?> getString(String key) async => _data[key];

  @override
  Future<void> putString(String key, String value) async {
    _data[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    _data.remove(key);
  }

  @override
  Future<void> clear() async {
    _data.clear();
  }
}
