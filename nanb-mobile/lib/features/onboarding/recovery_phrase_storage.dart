import '../../core/secure_storage/secure_storage.dart';

/// Persists the BIP-39 recovery phrase post-onboarding so the user can
/// re-reveal it from settings. Phrase is tied to the identity keypair —
/// `Delete account` clears it alongside `CryptoBridge.wipe()`.
class RecoveryPhraseStorage {
  RecoveryPhraseStorage(this._storage);

  final SecureStorage _storage;

  static const _key = 'identity.recovery_phrase';

  Future<void> save(String phrase) => _storage.putString(_key, phrase);
  Future<String?> read() => _storage.getString(_key);
  Future<void> clear() => _storage.delete(_key);
}
