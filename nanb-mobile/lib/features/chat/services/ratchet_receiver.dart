import 'dart:async';

import '../../../core/crypto/conversation_crypto_state.dart';
import '../../../core/crypto/crypto_bridge.dart';
import '../../../core/models/envelope.dart' as wire;
import '../models/chat_message.dart';
import '../models/conversation.dart';
import '../models/crypto_mode.dart';
import '../models/message_kind.dart';
import '../models/system_event.dart';
import 'device_cache.dart';
import 'message_appender.dart';
import 'notifier_service_host.dart';
import 'ratchet_core.dart';

/// The v1 (pre-MLS) ratchet RECEIVE path — the inbound counterpart to
/// [RatchetCore]: resolve the per-sender ratchet, decrypt a text_legacy
/// envelope (with peer-reset recovery for the primary chain), and hand the
/// plaintext to [MessageAppender]. Always invoked from inside the conversation
/// decrypt lock (by `_onEnvelope`), so it mutates live state directly. Extracted
/// from `ConversationsNotifier`.
class RatchetReceiver {
  RatchetReceiver({
    required NotifierServiceHost host,
    required CryptoBridge crypto,
    required RatchetCore ratchetCore,
    required DeviceCache deviceCache,
    required MessageAppender appender,
    required bool Function(Conversation) isUnknownPeerPlaceholder,
    required Future<void> Function(wire.Envelope) appendUnknownPeerEnvelope,
    required Future<void> Function(Conversation) warmDeviceCaches,
    required Future<void> Function(String, String, String) requestReestablish,
  })  : _host = host,
        _crypto = crypto,
        _ratchetCore = ratchetCore,
        _deviceCache = deviceCache,
        _appender = appender,
        _isUnknownPeerPlaceholder = isUnknownPeerPlaceholder,
        _appendUnknownPeerEnvelope = appendUnknownPeerEnvelope,
        _warmDeviceCaches = warmDeviceCaches,
        _requestReestablish = requestReestablish;

  final NotifierServiceHost _host;
  final CryptoBridge _crypto;
  final RatchetCore _ratchetCore;
  final DeviceCache _deviceCache;
  final MessageAppender _appender;
  final bool Function(Conversation) _isUnknownPeerPlaceholder;
  final Future<void> Function(wire.Envelope) _appendUnknownPeerEnvelope;
  final Future<void> Function(Conversation) _warmDeviceCaches;

  /// Asks the MLS side to rebuild a diverged 1:1 group. Injected rather than
  /// reaching into `MlsReceiver`, so the two receive paths stay independent and
  /// this one is still testable without any MLS machinery.
  final Future<void> Function(String, String, String) _requestReestablish;

  /// Decrypts an inbound text_legacy (ratchet) envelope and appends it.
  Future<void> onTextLegacy(wire.Envelope env, String myDeviceId) async {
    final convoId = env.conversationId;
    var convo = _host.conversation(convoId);
    if (convo == null || _isUnknownPeerPlaceholder(convo)) {
      // Also retries resolution for placeholders persisted by an older build
      // (before sender auto-resolution shipped).
      await _appendUnknownPeerEnvelope(env);
      // Resolution seeds a real ratchet 1:1 for the sender. Decrypt THIS
      // envelope now, in the same lock hold, instead of leaving it to the
      // detached held-envelope refetch. That refetch is a network round-trip
      // (seconds over Tor) and the request row was already on screen EMPTY
      // while it ran — the "all they receive is the invitation" report. Worse,
      // anything that migrated the 1:1 to MLS in that window (the recipient
      // opening the request → warm-up, or our own delivered receipt as the
      // migration leader) turned the first message into a text_legacy for an
      // MLS-mode 1:1, which was never decrypted and ended up ack+dropped.
      final resolved = _host.conversation(convoId);
      if (resolved == null ||
          _isUnknownPeerPlaceholder(resolved) ||
          resolved.cryptoMode != CryptoMode.ratchet) {
        return; // unresolved placeholder / group stub — stays unacked
      }
      convo = resolved;
    }
    // Idempotency by envelope id. The held-envelope refetch (and a live push
    // racing a catchup) can hand back an envelope we already rendered; on the
    // ratchet it would then fail as a stale counter, "recover" by re-seeding
    // the chain, and render the message a second time.
    if (convo.messages.any((m) => m.envelopeId == env.envelopeId)) {
      await _host.ack([env.envelopeId]);
      return;
    }
    if (convo.cryptoMode != CryptoMode.ratchet) {
      await _onTextLegacyForMlsConvo(convo, env, myDeviceId);
      return;
    }
    // Route to the ratchet for the SENDING device. The peer's primary device
    // uses the legacy '' ratchet (single-device baseline); other peer devices
    // and this account's own devices (self-sync) use their own device-keyed
    // ratchet seeded from that device's X25519.
    final isPrimarySender = env.senderDeviceId == convo.peerDeviceId;
    final cryptoState = await _ratchetStateForSender(convo, env.senderDeviceId);
    if (cryptoState == null) {
      // No ratchet + couldn't resolve the sender's X25519 — drop the envelope.
      // ignore: avoid_print
      print('text_legacy ${env.envelopeId}: no crypto state for $convoId '
          'sender=${env.senderDeviceId} — dropped');
      return;
    }
    DecryptResult? decrypted;
    try {
      decrypted = await _crypto.decryptMessage(
        state: cryptoState,
        ciphertext: env.ciphertext,
      );
    } catch (e) {
      // Decrypt failed. For the primary '' ratchet, attempt re-key recovery (a
      // peer that wiped its device + restored from the same phrase re-seeds a
      // fresh chain at counter 0; the unchanged X25519 lets us realign — see
      // [_tryRecoverRatchet]). Device-keyed ratchets just drop on failure.
      decrypted = isPrimarySender
          ? await _tryRecoverRatchet(convo, env, cryptoState)
          : null;
      if (decrypted == null) {
        // Tampered, corrupt, skip-window exceeded, or not a peer reset — drop
        // it, leaving the on-disk ratchet untouched. Logged (without plaintext/
        // key material) because a systematic chain mismatch otherwise looks
        // like silent non-delivery.
        // ignore: avoid_print
        print('text_legacy ${env.envelopeId}: decrypt failed for $convoId '
            '(recvCounter=${cryptoState.recvCounter}): $e — dropped');
        return;
      }
    }
    await _host.db.saveConversationCryptoState(decrypted.newState);

    await _appender.append(
      env: env,
      myDeviceId: myDeviceId,
      plaintext: decrypted.plaintext,
    );
  }

  /// An inbound text_legacy for a 1:1 we hold as MLS. Two very different
  /// situations look like this:
  ///
  /// - **Split brain** — the peer lost our group (thread deleted, device
  ///   erased, store restored from the recovery phrase) and dropped back to the
  ///   v1 ratchet, which it re-seeds from scratch. Same definitive evidence as
  ///   an undecryptable MLS envelope, so re-establish (measured on-device
  ///   2026-08-20: ratchet envelopes to an MLS-mode peer were acked 0 of 12).
  /// - **Migration race** — WE just migrated (first send / delivered receipt /
  ///   warm-up as the leader) and the peer sent this on its ORIGINAL ratchet
  ///   before it processed our Welcome. Typical at first contact.
  ///
  /// Either way the message is still readable: the ratchet is derived from the
  /// peer's unchanged X25519 key, exactly as [_tryRecoverRatchet] re-derives
  /// it. It used to be left unacked "so a redelivery can decrypt after
  /// re-establishment flips the 1:1 back to ratchet" — but re-establishment
  /// immediately re-migrates (it ships a fresh Welcome), so every redelivery
  /// found MLS again until the backstop ack+dropped it: the message was lost.
  /// Now it is decrypted and delivered, and only a peer whose chain restarted
  /// (counter 0, or one we can't open) triggers re-establishment — rebuilding
  /// the group under a peer that is merely about to adopt it would discard
  /// whatever it sends in the group it just joined.
  Future<void> _onTextLegacyForMlsConvo(
      Conversation convo, wire.Envelope env, String myDeviceId) async {
    final late = await _decryptOnFreshRatchet(convo, env);
    final peerRestartedRatchet = late == null || late.newState.recvCounter <= 1;
    if (peerRestartedRatchet) {
      // ignore: avoid_print
      print('inbound text_legacy for mls-mode convo ${convo.id}; '
          're-establishing');
      // Detached, NOT awaited: this runs inside the conversation lock and
      // re-establishment re-takes that lock, so awaiting it here deadlocks the
      // whole receive path. `MlsReceiver` defers its own call for exactly this
      // reason.
      unawaited(Future(() =>
          _requestReestablish(convo.id, env.senderDeviceId, myDeviceId)));
    }
    // Undecryptable: leave it unacked (bounded by the catchup backstop).
    if (late == null) return;
    await _appender.append(
      env: env,
      myDeviceId: myDeviceId,
      plaintext: late.plaintext,
    );
  }

  /// Decrypts [env] from the primary peer on a chain re-derived from the
  /// peer's X25519 key, WITHOUT touching any stored state (an MLS-mode 1:1
  /// keeps none). Null when the sender isn't the primary peer device, no key is
  /// known, or it doesn't open.
  Future<DecryptResult?> _decryptOnFreshRatchet(
      Conversation convo, wire.Envelope env) async {
    if (env.senderDeviceId != convo.peerDeviceId ||
        convo.peerX25519PubKey.isEmpty) {
      return null;
    }
    try {
      final fresh = await _crypto.initConversationCrypto(
        conversationId: convo.id,
        peerX25519PubKey: convo.peerX25519PubKey,
      );
      return await _crypto.decryptMessage(
        state: fresh,
        ciphertext: env.ciphertext,
      );
    } catch (_) {
      return null;
    }
  }

  /// Resolves the ratchet to decrypt an inbound text_legacy envelope from
  /// [senderDeviceId]: the primary peer uses the '' ratchet; other peer/own
  /// devices use a device-keyed ratchet, seeding it from that device's X25519
  /// (warming the device caches on a cold miss).
  Future<ConversationCryptoState?> _ratchetStateForSender(
      Conversation convo, String senderDeviceId) async {
    if (senderDeviceId == convo.peerDeviceId) {
      return _ratchetCore.loadOrInitCryptoState(convo); // '' ratchet
    }
    final existing = await _host.db
        .loadConversationCryptoState(convo.id, peerDeviceId: senderDeviceId);
    if (existing != null) return existing;
    var x = _deviceCache.x25519ForSender(convo, senderDeviceId);
    if (x.isEmpty) {
      await _warmDeviceCaches(convo);
      x = _deviceCache.x25519ForSender(convo, senderDeviceId);
    }
    if (x.isEmpty) return null;
    return _ratchetCore.loadOrInitDeviceRatchet(
        conversationId: convo.id, ratchetKey: senderDeviceId, x25519: x);
  }

  /// Recovers from a decrypt failure caused by a peer that reset its ratchet
  /// (wiped device, restored from the same recovery phrase). Re-seeds from the
  /// peer's UNCHANGED X25519 key and retries; self-authenticating (only the
  /// real peer's ciphertext decrypts under the re-seeded chain). Recv-only:
  /// preserves our SEND chain/counter so we don't trigger a mutual-reset storm.
  Future<DecryptResult?> _tryRecoverRatchet(
    Conversation convo,
    wire.Envelope env,
    ConversationCryptoState current,
  ) async {
    if (convo.peerX25519PubKey.isEmpty) return null;

    // Drop the stale in-memory skipped-key cache from the old chain so it can't
    // shadow the freshly-derived keys.
    _crypto.clearConversationCrypto(convo.id);

    final ConversationCryptoState fresh;
    try {
      fresh = await _crypto.initConversationCrypto(
        conversationId: convo.id,
        peerX25519PubKey: convo.peerX25519PubKey,
      );
    } catch (_) {
      return null;
    }

    final DecryptResult result;
    try {
      result = await _crypto.decryptMessage(
        state: fresh,
        ciphertext: env.ciphertext,
      );
    } catch (_) {
      // Genuinely undecryptable even from a fresh root — not a peer reset.
      return null;
    }

    // ignore: avoid_print
    print('text_legacy ${env.envelopeId}: peer ratchet reset detected for '
        '${convo.id} — re-established from unchanged X25519 key');
    // Only a chain that already received something can have been RESET. A
    // miss on the very first inbound message is a first-contact seeding
    // difference, and "re-established" there just confuses a new contact.
    if (current.recvCounter > 0) await _injectSessionReestablished(convo);
    // Recv-only: keep our existing send chain/counter, adopt the fresh recv.
    final recvOnly = result.newState.copyWith(
      sendCounter: current.sendCounter,
      sendChainKey: current.sendChainKey,
    );
    return DecryptResult(plaintext: result.plaintext, newState: recvOnly);
  }

  /// Appends a local-only "secure session re-established" system line and
  /// clears [Conversation.needsReestablishment]. Deduped to once per 5-minute
  /// window. Runs inside the conversation lock.
  Future<void> _injectSessionReestablished(Conversation convo) async {
    final now = DateTime.now().toUtc();
    final cutoff = now.subtract(const Duration(minutes: 5));
    final live = _host.conversation(convo.id) ?? convo;
    final dup = live.messages
        .where(
            (m) => m.kind == MessageKind.system && m.serverTs.isAfter(cutoff))
        .map((m) => SystemEvent.tryDecode(m.body))
        .any((ev) => ev?.kind == SystemEventKind.sessionReestablished);

    if (dup) {
      // Still make sure the re-establishment flag is cleared.
      if (live.needsReestablishment) {
        final cleared = live.copyWith(needsReestablishment: false);
        _host.setConversation(convo.id, cleared);
        await _host.db.upsertConversation(cleared);
      }
      return;
    }

    final synthetic = ChatMessage(
      envelopeId: 'local-syn-reestablished-${now.toIso8601String()}',
      conversationId: convo.id,
      senderDeviceId: 'system',
      body: SystemEvent.sessionReestablished(
        username: convo.peerUsername,
        at: now,
      ).toJsonString(),
      serverTs: now,
      mine: false,
      kind: MessageKind.system,
    );
    final updated = live.copyWith(
      messages: [...live.messages, synthetic],
      needsReestablishment: false,
    );
    _host.setConversation(convo.id, updated);
    await _host.db.upsertConversation(updated);
    await _host.db.upsertMessages(convo.id, [synthetic]);
  }
}
