import '../../core/crypto/crypto_bridge.dart';
import '../../core/models/jwt_session.dart';
import '../../core/network/api_client.dart';
import 'recovery_phrase.dart';
import 'recovery_phrase_storage.dart';
import 'session_repository.dart';

/// Thrown when the typed phrase is neither a valid BIP-39 mnemonic nor an
/// acceptable custom phrase (≥ [RecoveryPhrase.minCustomWords] words).
class InvalidRecoveryPhraseException implements Exception {
  const InvalidRecoveryPhraseException();
}

/// Drives the recovery-phrase restore flow:
///   1. Check the phrase is acceptable (BIP-39 of any length — incl. legacy
///      24-word — or a custom phrase).
///   2. Re-derive the Ed25519 identity keypair from it (overwrites the local
///      identity in `SecureStorage` via `CryptoBridge.generateIdentity`).
///   3. Hit `POST /sessions/restore/challenge` for a server-issued nonce.
///   4. Sign it with the freshly-restored identity key.
///   5. Hit `POST /sessions/restore` to receive `account_id` + `device_id` +
///      `jwt`. Persist via `SessionRepository`.
class RestoreNotifier {
  RestoreNotifier({
    required ApiClient apiClient,
    required CryptoBridge crypto,
    required SessionRepository sessions,
    required RecoveryPhraseStorage phraseStorage,
  })  : _api = apiClient,
        _crypto = crypto,
        _sessions = sessions,
        _phraseStorage = phraseStorage;

  final ApiClient _api;
  final CryptoBridge _crypto;
  final SessionRepository _sessions;
  final RecoveryPhraseStorage _phraseStorage;

  Future<JwtSession> restoreFromPhrase({
    required String username,
    required String phrase,
  }) async {
    if (!RecoveryPhrase.isAcceptable(phrase)) {
      throw const InvalidRecoveryPhraseException();
    }
    // Same normalization as sign-up so custom phrases re-derive the same
    // seed regardless of casing/whitespace.
    final normalized = RecoveryPhrase.normalize(phrase);
    final seed = RecoveryPhrase.toSeed(normalized);
    final identity = await _crypto.generateIdentity(seed: seed);

    // Open the CoreCrypto store now that the identity seed is on disk.
    // BEST-EFFORT — an unopenable store must not block recovery. This threw
    // out of restoreFromPhrase before, which meant a user whose CoreCrypto
    // store was broken could neither create an account NOR restore one: the
    // recovery phrase, the whole point of which is to get back in from a bad
    // state, hit the identical MlsIoException. Retried below.
    try {
      await _crypto.mlsInit();
    } catch (e) {
      // ignore: avoid_print
      print('restore: MLS store init failed: $e — retrying post-restore');
    }

    final reply = await _api.requestRestoreChallenge(username: username);
    final signature = await _crypto.signWithIdentity(identity, reply.challenge);

    final session = await _api.submitRestoreSession(
      username: username,
      identityPubKey: identity.publicKey,
      challenge: reply.challenge,
      signature: signature,
      // Mint this phone as a NEW, distinct device and revoke the account's
      // others — recovery phrase = "this phone is now my account". The device
      // key is the phrase-derived identity (same as a fresh sign-up); the old
      // phone is kicked + wiped on its next reconnect.
      devicePubKey: identity.publicKey,
      x25519PubKey: identity.x25519PublicKey,
    );
    await _sessions.save(session);
    await _phraseStorage.save(normalized);

    // The restore wiped the CoreCrypto store, so every key package this
    // device previously published is dead (its private key is gone). The
    // server purges those stale packages during the restore call above;
    // here we mint + publish a FRESH batch (same as account creation) so
    // peers can invite us to MLS groups with packages we can actually use.
    // Without this the pool sits empty and peers fall back to the ratchet.
    //
    // Set the bearer on the shared client first — restore doesn't go
    // through connect() yet, so authed calls would otherwise 401.
    _api.setBearerToken(session.jwt);
    try {
      // Idempotent once open; the retry for a store that failed above.
      await _crypto.mlsInit();
      await _crypto.mlsEnsureClient(session.deviceId);
      final kps = await _crypto.mintKeyPackages(count: 100);
      await _api.publishKeyPackages(kps);
    } catch (e) {
      // Non-fatal: the KeyPackage replenishment task retries on the next
      // foreground/reconnect. Senders fall back to the ratchet until then.
      // ignore: avoid_print
      print('restore: MLS client init / KeyPackage publish failed: $e — '
          'will replenish on next foreground');
    }
    return session;
  }
}
