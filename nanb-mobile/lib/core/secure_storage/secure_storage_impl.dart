import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'secure_storage.dart';

/// Production wrapper around flutter_secure_storage. Excluded from coverage.
///
/// **iOS:** writes under the app's DEFAULT Keychain access group (the
/// application-identifier), which any signing identity grants. We do NOT use a
/// custom shared Keychain group: a concrete shared `keychain-access-groups`
/// entitlement can't be embedded per-target by the Windows signer (zsign only
/// carries the provisioning profile's team WILDCARD, which iOS doesn't honor for
/// explicit cross-group access — every write then fails with -34018). The
/// Notification Service Extension instead reads the few values it needs from an
/// **App Group** container file the app mirrors there (see `IosSharedStore` /
/// `ios/Runner/SharedStoreChannel.swift` and `ios/NanbNotificationService`),
/// because the App Group entitlement IS concrete in the profile.
class SecureStorageImpl implements SecureStorage {
  SecureStorageImpl()
      : _impl = const FlutterSecureStorage(
          aOptions: AndroidOptions(encryptedSharedPreferences: true),
          iOptions: IOSOptions(
            accessibility: KeychainAccessibility.unlocked_this_device,
          ),
        );

  final FlutterSecureStorage _impl;

  @override
  Future<String?> getString(String key) => _impl.read(key: key);

  @override
  Future<void> putString(String key, String value) =>
      _impl.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _impl.delete(key: key);

  @override
  Future<void> clear() => _impl.deleteAll();
}
