import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../../core/crypto/crypto_bridge.dart';
import '../../core/models/jwt_session.dart';
import '../../core/network/api_client.dart';
import 'recovery_phrase.dart';
import 'recovery_phrase_storage.dart';
import 'restore_notifier.dart' show InvalidRecoveryPhraseException;
import 'session_repository.dart';

/// Snapshot returned to the UI after a successful registration.
@immutable
class OnboardingResult {
  const OnboardingResult({
    required this.session,
    required this.recoveryPhrase,
  });

  final JwtSession session;

  /// The (normalized) recovery phrase the identity was seeded from —
  /// generated 12-word BIP-39 or the user's own words. Shown once; user
  /// must back up out of band.
  final String recoveryPhrase;
}

/// Drives the account-creation flow.
class OnboardingNotifier {
  OnboardingNotifier({
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

  /// Canonical claim payload mirrored from the server's
  /// `identity.UsernameClaimPayload`.
  static List<int> usernameClaimPayload(String username, List<int> identityPubKey) {
    final out = BytesBuilder();
    out.add(const _Ascii('nanb-username-claim-v1:').bytes);
    out.add(_Ascii(username).bytes);
    out.addByte(0x7C); // '|'
    out.add(identityPubKey);
    return out.toBytes();
  }

  Future<OnboardingResult> createAccount({
    required String username,
    String? recoveryPhrase,
  }) async {
    // Behavioral strength gate. The phrase-setup screen also disables its
    // create button on a weak phrase, but that UI check is only advisory — the
    // notifier is the real gate. A caller-supplied CUSTOM phrase must clear the
    // creation-strength bar BEFORE we derive the immutable identity key or hit
    // the server; a null phrase means "generate for me" (always a strong
    // 12-word BIP-39 mnemonic) and is exempt. Rejection surfaces as the same
    // InvalidRecoveryPhraseException the restore path already throws for phrase
    // validation failures.
    if (recoveryPhrase != null &&
        !RecoveryPhrase.meetsCreationStrength(recoveryPhrase)) {
      throw const InvalidRecoveryPhraseException();
    }

    // The recovery phrase deterministically seeds the identity keypair, so
    // it must be fixed BEFORE the account exists. The phrase-setup screen
    // passes the user's choice (generated or their own words); when absent
    // we generate a fresh 12-word mnemonic. Normalized so a custom phrase
    // restores regardless of casing/whitespace.
    final phrase = recoveryPhrase != null
        ? RecoveryPhrase.normalize(recoveryPhrase)
        : RecoveryPhrase.generate();
    final seed = RecoveryPhrase.toSeed(phrase);
    final identity = await _crypto.generateIdentity(seed: seed);

    // Open the CoreCrypto store now that the identity seed is on disk.
    // BEST-EFFORT, same rule the boot path (app.dart `_maybeInitMls`) already
    // follows: broken MLS must not strand the user. It used to throw straight
    // out of createAccount, so an unopenable CoreCrypto store meant the user
    // could not create an account AT ALL — no ratchet fallback, no retry, just
    // the raw MlsIoException on screen. The store is retried below (and again
    // every foreground), and 1:1 chats work on the ratchet meanwhile.
    try {
      await _crypto.mlsInit();
    } catch (e) {
      // ignore: avoid_print
      print('createAccount: MLS store init failed: $e — retrying post-create');
    }

    // No key packages in the create payload: real CoreCrypto KPs need the
    // MLS client, which needs the server-assigned device id — so the
    // 100-batch publishes right after createAccount instead. (The old
    // legacy-ratchet mintKeyPackage(identity) bytes published here were
    // junk CoreCrypto can't parse; they made every MLS migration against
    // a fresh account fail its addMember and fall back to ratchet.)
    final claim = usernameClaimPayload(username, identity.publicKey);
    final signature = await _crypto.signWithIdentity(identity, claim);

    // Plan 6a uses the same Ed25519 keypair for identity + first device.
    // Plan 6 (full) gives each device its own MLS leaf keypair.
    final JwtSession session;
    try {
      session = await _api.createAccount(
        CreateAccountPayload(
          username: username,
          identityPubKey: identity.publicKey,
          x25519PubKey: identity.x25519PublicKey,
          devicePubKey: identity.publicKey,
          signedClaim: signature,
          keyPackages: const [],
        ),
      );
    } catch (e) {
      // A failed create (e.g. 409 username_taken / identity_key_taken) leaves
      // the CoreCrypto store opened+keyed under THIS attempt's seed. The user
      // can retry in-place (regenerate the phrase / pick a new name), which
      // generates a NEW seed — but mlsInit() would early-return because the
      // store is already open under the old seed, so future key packages would
      // be minted against a store the app discards on next cold start (dropped
      // Welcomes). Wipe the (empty, account-less) store so the retry re-opens
      // cleanly under the new seed.
      try {
        await _crypto.mlsWipe();
      } catch (_) {/* best-effort; the cold-start self-heal is the backstop */}
      rethrow;
    }

    await _sessions.save(session);
    await _phraseStorage.save(phrase);

    // Mint + publish an initial batch of 100 KeyPackages so peers can invite
    // us to MLS groups without first needing us to come online.
    // mlsEnsureClient needs the server-assigned device id, so it can only
    // run now (post-createAccount) — and minting requires it.
    try {
      // Re-run mlsInit: it is idempotent (a no-op once the store is open), so
      // this is free on the happy path and is the retry for a store that
      // failed to open above — by now the native side has purged a stale
      // store, so the second attempt is the one that lands.
      await _crypto.mlsInit();
      await _crypto.mlsEnsureClient(session.deviceId);
      final kps = await _crypto.mintKeyPackages(count: 100);
      await _api.publishKeyPackages(kps);
    } catch (e) {
      // Non-fatal: account is created, just no KPs yet. The KeyPackage
      // replenishment task (Plan B Task 15) will retry on app foreground.
      // ignore: avoid_print
      print('initial KeyPackage publish failed: $e — will retry on next foreground');
    }

    return OnboardingResult(
      session: session,
      recoveryPhrase: phrase,
    );
  }
}

class _Ascii {
  const _Ascii(this.value);
  final String value;
  List<int> get bytes {
    return value.codeUnits;
  }
}
