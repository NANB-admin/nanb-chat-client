import 'package:flutter/foundation.dart';

import '../../core/crypto/crypto_bridge.dart';
import '../../core/crypto/mls_exceptions.dart';
import '../../core/network/api_client.dart';
import 'models/conversation.dart';
import 'models/crypto_mode.dart';

/// Captures the outcome of [MlsMigrator.encryptForSend]. The caller
/// (ConversationsNotifier) consumes [ciphertext] + [welcomeBytes]:
/// - welcomeBytes non-null: send a 'mls_welcome' envelope FIRST,
///   then the application envelope with [envelopeType].
/// - welcomeBytes null: just send the application envelope.
class MigrationResult {
  const MigrationResult({
    required this.newMode,
    required this.envelopeType,
    required this.ciphertext,
    this.welcomeBytes,
    this.welcomeRecipientDeviceId,
  });

  final CryptoMode newMode;
  final String envelopeType; // 'mls_application' or 'text_legacy'
  final List<int> ciphertext;
  final List<int>? welcomeBytes;
  final String? welcomeRecipientDeviceId;
}

class MlsMigrator {
  MlsMigrator({
    required this.bridge,
    required this.apiClient,
    required this.legacyEncryptOnRatchet,
    this.myAccountId = '',
  });

  final CryptoBridge bridge;
  final ApiClient apiClient;

  /// This account's id, used by [_initiatesMigration] for the deterministic-
  /// migration rule. Empty disables the rule (migration always allowed) so
  /// callers that don't supply it keep the prior behavior.
  final String myAccountId;

  /// Deterministic migration: only the lexicographically-smaller account
  /// initiates the ratchet→MLS migration, so the two sides can't both create a
  /// group at once (the simultaneous-migration collision). The larger account
  /// stays on ratchet and adopts the smaller account's Welcome. Mirrors
  /// [Conversation.oneToOneId]'s account sort + the "smallest id is the adder"
  /// rule. When the ordering can't be determined (account ids unknown), migration
  /// is allowed — the receive-side adopt + split-brain recovery still converge.
  bool _initiatesMigration(Conversation convo) {
    final peer = convo.peerAccountId;
    if (myAccountId.isEmpty || peer.isEmpty) return true;
    return myAccountId.compareTo(peer) < 0;
  }

  /// Callback the migrator invokes for the ratchet (text_legacy) path.
  /// ConversationsNotifier injects its existing Plan 13.1 ratchet encrypt
  /// logic here so the migrator doesn't need to know about
  /// ConversationCryptoState etc.
  final Future<List<int>> Function(Conversation, List<int>) legacyEncryptOnRatchet;

  /// Encrypt [plaintext] for [convo]. If convo is `ratchet`-mode, attempt
  /// migration on this send.
  Future<MigrationResult> encryptForSend({
    required Conversation convo,
    required List<int> plaintext,
    bool forceMigration = false,
  }) async {
    if (convo.cryptoMode == CryptoMode.mls) {
      final ct = await bridge.encrypt(groupId: convo.id, plaintext: plaintext);
      return MigrationResult(
        newMode: CryptoMode.mls,
        envelopeType: 'mls_application',
        ciphertext: ct,
      );
    }

    // ratchet-mode — attempt migration only if we're the designated initiator
    // (the smaller account; see [_initiatesMigration]). The larger account stays
    // on ratchet and adopts the peer's Welcome instead, so the two can't both
    // migrate at once. A re-establishment passes [forceMigration] to rebuild the
    // group regardless, so a stranded follower isn't left unable to recover.
    if (!forceMigration && !_initiatesMigration(convo)) {
      return _encryptOnRatchet(convo, plaintext);
    }

    // attempt migration
    try {
      final kpResult = await apiClient.lookupKeyPackage(convo.peerUsername);
      try {
        return await _migrateWithKeyPackage(convo, plaintext, kpResult);
      } on MlsException catch (e) {
        // Most likely createGroup hit a half-created group orphaned by an
        // EARLIER failed migration (this convo would otherwise never leave
        // ratchet, and the orphan also breaks the peer's inbound Welcome).
        // Wipe the orphan and retry once — the fetched key package was never
        // successfully consumed, so reusing it is safe.
        debugPrint(
            'mls migrate: ${convo.id} failed ($e); wiping local group and '
            'retrying once');
        await bridge.wipeGroup(convo.id); // throws if nothing to wipe
        return await _migrateWithKeyPackage(convo, plaintext, kpResult);
      }
    } on StateError {
      // §7.3 invariant violation — propagate; this is a programming error.
      rethrow;
    } on AccountNotFoundException {
      // peer hasn't upgraded yet — stay on ratchet
      return _encryptOnRatchet(convo, plaintext);
    } on KeyPackageExhaustedException {
      // peer ran out of KPs — stay on ratchet
      return _encryptOnRatchet(convo, plaintext);
    } catch (e) {
      // network / unexpected — stay on ratchet. NOT silent: a fallback here
      // means the conversation stays ratchet until the next send (or, before
      // the orphan-cleanup above existed, forever — see the 2026-06-07
      // poisoned-conversation incident).
      debugPrint('mls migrate: ${convo.id} fell back to ratchet: $e');
      return _encryptOnRatchet(convo, plaintext);
    }
  }

  /// One migration attempt with an already-fetched key package. On any
  /// failure AFTER the local group was created, best-effort wipes the group
  /// before rethrowing — a half-created group otherwise poisons both the
  /// retry path (`createGroup` → "already exists") and the peer's inbound
  /// Welcome for the same conversation id.
  Future<MigrationResult> _migrateWithKeyPackage(
    Conversation convo,
    List<int> plaintext,
    FetchKeyPackageResult kpResult,
  ) async {
    final groupId = await bridge.createGroup(conversationId: convo.id);
    // §7.3 invariant — assert defensively
    if (groupId != convo.id) {
      throw StateError(
        'spec §7.3 violated: bridge.createGroup returned $groupId, expected ${convo.id}',
      );
    }
    try {
      final addResult = await bridge.addMember(
        groupId: groupId,
        peerKeyPackage: kpResult.keyPackage,
      );
      // In the 1:1 migration case there are no existing members to fan the
      // Commit out to — the peer is about to receive the Welcome and will
      // bootstrap their own group state from that. The Commit is discarded here.
      final ct = await bridge.encrypt(groupId: groupId, plaintext: plaintext);
      return MigrationResult(
        newMode: CryptoMode.mls,
        envelopeType: 'mls_application',
        ciphertext: ct,
        welcomeBytes: addResult.welcome,
        welcomeRecipientDeviceId: convo.peerDeviceId,
      );
    } catch (e) {
      try {
        await bridge.wipeGroup(groupId);
      } catch (wipeError) {
        debugPrint('mls migrate: cleanup wipe of $groupId failed: $wipeError');
      }
      rethrow;
    }
  }

  /// Eagerly migrates [convo] (ratchet → MLS) WITHOUT sending content: creates
  /// the group and adds the single-device peer, returning the Welcome to ship
  /// so the FIRST real send is a plain MLS application message instead of paying
  /// the migration round-trips inline.
  ///
  /// Returns null when migration isn't possible right now (already MLS / peer
  /// not upgraded / out of key packages / transient) — the caller stays on
  /// ratchet and migrates lazily on the next send, exactly as before. This is a
  /// strict subset of [encryptForSend]'s migration (it just omits the message
  /// encrypt), reusing the same orphan-group cleanup + single-retry posture.
  Future<({List<int> welcome, String recipientDeviceId})?> migrateOnly(
    Conversation convo,
  ) async {
    if (convo.cryptoMode == CryptoMode.mls) return null;
    // Warm-up is an INITIAL migration, so honor the deterministic-migration
    // rule: the larger account waits to adopt instead of pre-creating a group.
    if (!_initiatesMigration(convo)) return null;
    try {
      final kpResult = await apiClient.lookupKeyPackage(convo.peerUsername);
      try {
        return await _migrateOnlyWithKeyPackage(convo, kpResult);
      } on MlsException catch (e) {
        // Same orphan-from-an-earlier-failed-migration recovery as
        // encryptForSend: wipe the half-created group and retry once (the key
        // package was never consumed if createGroup was what failed).
        debugPrint(
            'mls warm-up: ${convo.id} failed ($e); wiping local group + retry');
        await bridge.wipeGroup(convo.id);
        return await _migrateOnlyWithKeyPackage(convo, kpResult);
      }
    } on StateError {
      rethrow; // §7.3 invariant — programming error
    } on AccountNotFoundException {
      return null; // peer hasn't upgraded — stay ratchet
    } on KeyPackageExhaustedException {
      return null; // peer out of key packages — stay ratchet
    } catch (e) {
      // Network / unexpected — stay ratchet; the next send migrates lazily.
      debugPrint('mls warm-up: ${convo.id} skipped: $e');
      return null;
    }
  }

  Future<({List<int> welcome, String recipientDeviceId})?>
      _migrateOnlyWithKeyPackage(
    Conversation convo,
    FetchKeyPackageResult kpResult,
  ) async {
    final groupId = await bridge.createGroup(conversationId: convo.id);
    if (groupId != convo.id) {
      throw StateError(
        'spec §7.3 violated: bridge.createGroup returned $groupId, expected ${convo.id}',
      );
    }
    try {
      final addResult = await bridge.addMember(
        groupId: groupId,
        peerKeyPackage: kpResult.keyPackage,
      );
      return (welcome: addResult.welcome, recipientDeviceId: convo.peerDeviceId);
    } catch (e) {
      try {
        await bridge.wipeGroup(groupId);
      } catch (wipeError) {
        debugPrint('mls warm-up: cleanup wipe of $groupId failed: $wipeError');
      }
      rethrow;
    }
  }

  Future<MigrationResult> _encryptOnRatchet(
    Conversation convo,
    List<int> plaintext,
  ) async {
    final ct = await legacyEncryptOnRatchet(convo, plaintext);
    return MigrationResult(
      newMode: CryptoMode.ratchet,
      envelopeType: 'text_legacy',
      ciphertext: ct,
    );
  }
}
