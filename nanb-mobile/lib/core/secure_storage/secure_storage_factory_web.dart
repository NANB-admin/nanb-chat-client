import 'secure_storage.dart';
import 'secure_storage_web.dart';

/// Browser: IndexedDB + a non-extractable WebCrypto key.
SecureStorage createSecureStorage() => SecureStorageWeb();
