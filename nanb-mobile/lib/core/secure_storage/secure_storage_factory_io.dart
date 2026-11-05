import 'secure_storage.dart';
import 'secure_storage_impl.dart';

/// Native: Keychain (iOS) / Keystore (Android) via flutter_secure_storage.
SecureStorage createSecureStorage() => SecureStorageImpl();
