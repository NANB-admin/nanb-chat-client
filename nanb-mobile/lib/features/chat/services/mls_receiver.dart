import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/crypto/crypto_bridge.dart';
import '../../../core/crypto/mls_exceptions.dart';
import '../../../core/models/account.dart';
import '../../../core/models/envelope.dart' as wire;
import '../../../core/network/api_client.dart';
import '../../onboarding/session_repository.dart';
import '../models/chat_message.dart';
import '../models/conversation.dart';
import '../models/conversation_kind.dart';
import '../models/crypto_mode.dart';
import '../models/message_control.dart';
import '../models/message_kind.dart';
import '../models/system_event.dart';
import 'control_sender.dart';
import 'device_cache.dart';
import 'envelope_retry_log.dart';
import 'message_appender.dart';
import 'notifier_service_host.dart';
import 'processed_envelope_log.dart';

/// The MLS RECEIVE engine: process Welcomes (join/adopt/replace group, with the
/// simultaneous-migration tiebreaker + orphan/poison handling), decrypt MLS
/// application + handshake messages, drive split-brain re-establishment, and
/// handle self-removal. The single most incident-hardened crypto path in the
/// app — this is a LINE-FOR-LINE faithful relocation from `ConversationsNotifier`
/// (logic preserved exactly; only dependencies are rewired). Always invoked from
/// inside the conversation decrypt lock (by `_onEnvelope`), except
/// [maybeReestablish], which re-takes the lock itself (it runs post-lock).
class MlsReceiver {
  MlsReceiver({
    required NotifierServiceHost host,
    required CryptoBridge crypto,
    required ApiClient api,
    required SessionRepository sessions,
    required DeviceCache deviceCache,
    required MessageAppender appender,
    required ControlSender controlSender,
    required Future<void> Function(wire.Envelope) appendUnknownPeerEnvelope,
    required bool Function(Conversation) isUnknownPeerPlaceholder,
    required void Function(Account) recordPeerDisplayName,
    required String Function(String convoId, String myAccountId)
        peerAccountFromOneToOneId,
    required EnvelopeRetryLog retryLog,
    required ProcessedEnvelopeLog processedLog,
  })  : _host = host,
        _retryLog = retryLog,
        _processedLog = processedLog,
        _crypto = crypto,
        _api = api,
        _sessions = sessions,
        _deviceCache = deviceCache,
        _appender = appender,
        _controlSender = controlSender,
        _appendUnknownPeerEnvelope = appendUnknownPeerEnvelope,
        _isUnknownPeerPlaceholder = isUnknownPeerPlaceholder,
        _recordPeerDisplayName = recordPeerDisplayName,
        _peerAccountFromOneToOneId = peerAccountFromOneToOneId;

  final NotifierServiceHost _host;
  final CryptoBridge _crypto;
  final ApiClient _api;
  final SessionRepository _sessions;
  final DeviceCache _deviceCache;
  final MessageAppender _appender;
  final ControlSender _controlSender;
  final Future<void> Function(wire.Envelope) _appendUnknownPeerEnvelope;
  final bool Function(Conversation) _isUnknownPeerPlaceholder;
  final void Function(Account) _recordPeerDisplayName;
  final String Function(String, String) _peerAccountFromOneToOneId;

  /// Consecutive inbound MLS-application decrypt failures per 1:1, cleared on
  /// the first success. Drives split-brain re-establishment.
  /// Durable per-envelope failure counts. Was an in-memory map, which reset on
  /// every app start — and a poison envelope fails exactly once per launch, so
  /// the drop threshold was unreachable and it re-drained forever.
  final EnvelopeRetryLog _retryLog;
  final ProcessedEnvelopeLog _processedLog;

  final Map<String, int> _mlsDecryptFailures = {};

  /// Per-envelope counter for MLS application messages we can't decrypt (sealed
  /// to a dead epoch — unrecoverable). Bounds redelivery so it stops churning.

  /// Foreign Welcomes we DISCARDED as the leader, per 1:1. Cleared on a
  /// successful decrypt from that peer (proof our group really is the live one)
  /// and whenever we adopt.
  ///
  /// This is what stops the deterministic role rule from stranding a peer
  /// FOREVER. The rule assumes both sides hold a working group and only need a
  /// tiebreak — but the common real failure is asymmetric: the peer signed out,
  /// switched phones, or deleted the thread, so it lost its MLS state entirely.
  /// It then rebuilds and sends a Welcome, which is its ONLY way to say "I
  /// cannot use your group any more". The leader, whose own group is perfectly
  /// healthy, has no decrypt failures of its own, so `leaderShouldYield` stayed
  /// false and it discarded that Welcome — every time, forever. Both sides then
  /// sat sending into groups the other could not open: the reported "we can see
  /// each other's chat but no message is ever delivered, and the only fix is to
  /// delete both chats or make new accounts".
  final Map<String, int> _discardedWelcomes = {};

  /// How many Welcomes the role rule may discard before we conclude it is not
  /// converging and adopt anyway.
  ///
  /// ONE. A simultaneous-migration collision — the only thing the role rule
  /// exists to settle — produces exactly one Welcome from each side, so a
  /// single discard fully preserves it. A SECOND Welcome cannot come from a
  /// collision; it means the peer rebuilt again because our group is unusable
  /// to it, and the only way out is to join theirs.
  static const int _maxDiscardedWelcomes = 1;

  /// Convos with a re-establishment in flight + the time of the last attempt
  /// (rate-limit so a flurry of old-group messages can't trigger a storm).
  final Set<String> _reestablishing = {};
  final Map<String, DateTime> _lastReestablish = {};

  /// Per-1:1 rate-limit for warming the peer device directory during inbound
  /// MLS sender authentication, so an unrecognised sender id triggers at most
  /// one account lookup per convo per window (never one per message).
  final Map<String, DateTime> _lastPeerDirWarm = {};

  static const int _mlsReestablishThreshold = 3;
  static const Duration _mlsReestablishCooldown = Duration(seconds: 45);
  static const Duration _mlsReestablishGrace = Duration(seconds: 6);
  static const int _maxUndecryptableRedeliveries = 5;

  /// Clears the decrypt-failure streak for [convoId] (e.g. when a Welcome
  /// arrives, proving the peer is rebuilding the group).
  void clearDecryptFailures(String convoId) =>
      _mlsDecryptFailures.remove(convoId);

  /// Records that the SEND path just rebuilt [convoId]'s group (its local group
  /// was gone). Starts the re-establish cooldown and supersedes any
  /// re-establishment already waiting on the conversation lock — which would
  /// otherwise wipe the fresh group and ship a second, competing Welcome.
  void noteLocalRebuild(String convoId) {
    _lastReestablish[convoId] = DateTime.now();
    _mlsDecryptFailures.remove(convoId);
  }

  /// Whether a failed Welcome adoption is PERMANENT for these bytes — i.e.
  /// re-delivering the SAME Welcome and re-running `replaceGroup` can never
  /// produce a different result, so the caller must fall through to the
  /// wipe+processWelcome hard reset instead of leaving it unacked.
  ///
  /// - [MlsArgumentException] — CoreCrypto rejected the Welcome (consumed key
  ///   package / malformed / conversation already exists).
  /// - [MlsUnknownGroupException] — there is NO local group under this id to
  ///   replace, so `replaceGroup`'s internal wipe throws before it ever gets to
  ///   the Welcome. This is the state a device is left in after CoreCrypto
  ///   drops the conversation on self-removal, so it is exactly the re-add
  ///   path: classifying it transient meant a re-invite Welcome was retried —
  ///   and failed identically — on every catchup, forever, leaving the user
  ///   stuck on "You were removed from this group" while the roster said
  ///   otherwise. The hard reset below processes it as a fresh join.
  ///
  /// Genuinely transient failures ([MlsIoException] etc.) return false and
  /// retry on the next catchup.
  static bool _isPermanentWelcomeFailure(Object e) =>
      e is MlsArgumentException || e is MlsUnknownGroupException;

  /// Adopts a peer's foreign Welcome onto [convoId], replacing whatever local
  /// group we hold. Tries [CryptoBridge.replaceGroup] first; on a PERMANENT
  /// failure (our local group is in a conflicting state replaceGroup can't
  /// reconcile) it HARD-RESETS — wipes the local group and processes the Welcome
  /// fresh — so we still join the peer's group rather than stranding
  /// undecryptable. Acks on success or permanent failure (the Welcome is
  /// consumed either way); leaves a TRANSIENT failure unacked to retry.
  Future<void> _adoptForeignWelcome(String convoId, wire.Envelope env) async {
    try {
      await _crypto.replaceGroup(
        localGroupId: convoId,
        foreignWelcome: env.ciphertext,
      );
      debugPrint('mls_welcome: adopted peer group on $convoId');
      _discardedWelcomes.remove(convoId);
      await _host.ack([env.envelopeId]);
      return;
    } catch (e) {
      if (!_isPermanentWelcomeFailure(e)) {
        debugPrint('mls_welcome: adopt failed on $convoId ($e); '
            'left unacked to retry');
        return; // transient — retried next catchup
      }
      debugPrint('mls_welcome: replaceGroup rejected on $convoId ($e); '
          'hard-resetting local group and retrying processWelcome');
    }
    // Permanent replaceGroup failure → wipe + process the Welcome fresh.
    try {
      await _crypto.wipeGroup(convoId);
    } catch (_) {/* nothing to wipe */}
    try {
      await _crypto.processWelcome(env.ciphertext);
      debugPrint('mls_welcome: adopted peer group on $convoId after hard reset');
    } catch (e2) {
      debugPrint('mls_welcome: hard-reset adopt failed on $convoId ($e2); '
          'acking to drop poison');
    }
    // Ack regardless: the Welcome bytes are consumed (single-use key package),
    // so re-delivering them can never help. Recovery now relies on a FRESH
    // Welcome from the peer's next re-establishment.
    await _host.ack([env.envelopeId]);
  }

  /// Ingests an MLS Welcome: process it, flip the conversation to MLS (creating
  /// a placeholder if needed), with the simultaneous-migration tiebreaker +
  /// orphan/poison handling.
  Future<void> onWelcome(wire.Envelope env, String myDeviceId) async {
    final convoId = env.conversationId;
    // A Welcome means the peer is (re)establishing the group, so clear any
    // decrypt-failure streak: we must NOT also fire our own re-establishment
    // (it would re-key away the message this Welcome unlocks, and cross with
    // the peer's group). Critically this covers FIRST CONTACT. Capture the
    // streak FIRST: a non-zero streak means we've been unable to decrypt this
    // peer's messages (split brain), which biases us toward ADOPTING this
    // Welcome rather than holding our own diverged group.
    final priorDecryptFailures = _mlsDecryptFailures[convoId] ?? 0;
    final hadDecryptFailures = priorDecryptFailures > 0;
    // Cleared here for every path EXCEPT the leader-keeps-own-group branch,
    // which RESTORES it — see the comment there for why blinding ourselves is
    // what made a stranded follower unrecoverable.
    _mlsDecryptFailures.remove(convoId);
    // Deterministic-migration role: the larger account is the FOLLOWER — it
    // never initiates a group (see MlsMigrator._initiatesMigration), so any
    // Welcome it receives is authoritative and it always adopts. Best-effort:
    // unknown account ids fall back to the device-id tiebreaker below.
    final myAccountId = (await _sessions.current())?.accountId ?? '';
    final peerAccountId = _peerAccountFromOneToOneId(convoId, myAccountId);
    final iAmFollower = myAccountId.isNotEmpty &&
        peerAccountId.isNotEmpty &&
        myAccountId.compareTo(peerAccountId) > 0;
    final existing = _host.conversation(convoId);

    if (existing != null && existing.cryptoMode == CryptoMode.mls) {
      // A fresh Welcome for a 1:1 we already track as MLS — re-establishment or
      // a simultaneous-migration collision. Resolution is ASYMMETRIC by account
      // role (deterministic ownership): the LEADER (smaller account) owns the
      // canonical group; the FOLLOWER always adopts the leader's group. This
      // breaks the adopt/adopt swap that otherwise leaves both sides stuck —
      // only one side's group ever survives, and the other converges onto it.
      final isOneToOne = existing.kind == ConversationKind.oneToOne;
      final hasReceivedReal = existing.messages.any(
        (m) => !m.mine && m.kind != MessageKind.system,
      );
      final roleKnown = myAccountId.isNotEmpty && peerAccountId.isNotEmpty;
      if (isOneToOne) {
        // Follower (or brand-new pending invite) → adopt the peer's group. When
        // the role is unknown (account ids missing) fall back to the prior
        // heuristics + the device-id tiebreaker below.
        // A LEADER that has been unable to decrypt this peer adopts too. The
        // role rule alone deadlocked a stranded FOLLOWER: `maybeReestablish`
        // deliberately rebuilds with `forceMigration: true` precisely so the
        // larger account can recover ("otherwise a stranded follower could
        // never recover") — but the leader branch below then discarded that
        // Welcome and kept its own group, so the follower's messages, sealed to
        // ITS new group, could never decrypt here. They stayed UNACKED, which
        // renders as "the message simply never arrives", forever. Observed live
        // 2026-07-28: iPhone (follower `bd2f…`) → Pixel (leader `6e66…`), three
        // Welcomes acked, every application envelope unacked.
        //
        // Decrypt failures are ASYMMETRIC evidence — only the side actually
        // failing adopts — so this cannot reintroduce the adopt/adopt swap the
        // role rule exists to prevent. The `_reestablishing` guard covers the
        // one case that could: both sides rebuilding at the same moment.
        //
        // ...and a leader that has ALREADY discarded a Welcome for this 1:1
        // yields to the next one. Decrypt failures are only available when the
        // peer is still sending to us; a peer that lost its MLS state (signed
        // out, switched phones, deleted the thread) leaves the leader's own
        // group working perfectly, so the leader never accumulates any — and
        // discarded the peer's rebuild every single time. A REPEAT Welcome is
        // the evidence that stands in for those missing failures: a collision
        // yields one Welcome per side, so a second one can only mean the peer
        // cannot use our group. See [_discardedWelcomes].
        final roleRuleNotConverging =
            (_discardedWelcomes[convoId] ?? 0) >= _maxDiscardedWelcomes;
        final leaderShouldYield =
            (hadDecryptFailures || roleRuleNotConverging) &&
                !_reestablishing.contains(convoId);
        if (iAmFollower ||
            existing.pending ||
            leaderShouldYield ||
            (!roleKnown && (hasReceivedReal || hadDecryptFailures))) {
          await _adoptForeignWelcome(convoId, env);
          return;
        }
        if (roleKnown) {
          // Count this discard, so the NEXT Welcome for this 1:1 is adopted
          // rather than discarded again (see [_discardedWelcomes]).
          _discardedWelcomes[convoId] =
              (_discardedWelcomes[convoId] ?? 0) + 1;
          // We're the LEADER — keep our group; ack so the Welcome stops
          // redelivering. The follower adopts ours; if OUR group is the stale
          // one, leader-driven re-establishment (maybeReestablish) rebuilds it.
          //
          // RESTORE the decrypt-failure streak we cleared above. Clearing it is
          // right when we ADOPT (the peer's group supersedes ours, so our own
          // re-establishment would only cross with it) — but here we are
          // DISCARDING their group and keeping ours, so their next messages
          // will keep failing to decrypt. Zeroing the counter on every inbound
          // Welcome meant the streak could never reach
          // `_mlsReestablishThreshold`, so a peer that re-established on a loop
          // kept resetting us and we never re-keyed: a livelock in which their
          // messages were silently dropped forever.
          _mlsDecryptFailures[convoId] = priorDecryptFailures;
          debugPrint('mls_welcome: keeping our leader group on $convoId '
              '(peer is the follower and will adopt ours)');
          await _host.ack([env.envelopeId]);
          return;
        }
        // Role unknown — legacy device-id tiebreaker as a last resort.
        if (myDeviceId.compareTo(env.senderDeviceId) < 0) {
          // Record it here too. This branch also DISCARDS a Welcome the peer
          // expects us to use, so it owes the same evidence as the leader
          // branch — without it, a discard decided by device id was invisible
          // to the decrypt-failure path and could never make us yield.
          _discardedWelcomes[convoId] = (_discardedWelcomes[convoId] ?? 0) + 1;
          // ignore: avoid_print
          print('Simultaneous-migration: ignoring foreign Welcome on $convoId '
              '(own deviceId $myDeviceId < sender ${env.senderDeviceId}; we win)');
          await _host.ack([env.envelopeId]);
          return;
        }
      }
      await _adoptForeignWelcome(convoId, env);
      return;
    }

    String groupId;
    try {
      groupId = await _crypto.processWelcome(env.ciphertext);
    } on MlsException catch (e) {
      // CoreCrypto rejected the Welcome — it ALREADY has a group under this
      // conversation id. (a) Our convo is RATCHET/GONE: the local group is an
      // ORPHAN — adopt the peer's Welcome via replaceGroup then fall through.
      // (b) Convo is already MLS: a genuine duplicate — ack idempotently.
      final ex = _host.conversation(convoId);
      String? adopted;
      if (ex == null || ex.cryptoMode != CryptoMode.mls) {
        try {
          adopted = await _crypto.replaceGroup(
            localGroupId: convoId,
            foreignWelcome: env.ciphertext,
          );
          debugPrint('mls_welcome: adopted foreign Welcome over orphaned '
              'local group on $convoId');
        } catch (e2) {
          // replaceGroup couldn't reconcile (the local group is in a conflicting
          // state — e.g. a half-built group from our own aborted migration).
          // Hard reset: wipe whatever's there and process the Welcome fresh so
          // we still JOIN the peer's group rather than stranding undecryptable.
          debugPrint('mls_welcome: orphan adoption failed on $convoId ($e2); '
              'hard-resetting local group and retrying');
          try {
            await _crypto.wipeGroup(convoId);
          } catch (_) {/* nothing to wipe */}
          try {
            adopted = await _crypto.processWelcome(env.ciphertext);
          } catch (e3) {
            debugPrint('mls_welcome: hard-reset adoption failed on $convoId '
                '($e3); falling back to ack-as-known');
          }
        }
      }
      if (adopted == null) {
        // ignore: avoid_print
        print('mls_welcome: processWelcome failed on $convoId ($e); '
            'treating as already-known and acking');
        if (convoId.startsWith('group:') &&
            (ex == null || _isUnknownPeerPlaceholder(ex))) {
          // The Welcome is unusable (poison) and we hold no real group
          // conversation. Leave a group-kind pending placeholder so (a) later
          // application envelopes don't seed a peerless 1:1 "unknown peer"
          // stub under the group id (unrepairable — copyWith pins `kind`),
          // and (b) a re-add Welcome from the group finds a group-kind MLS
          // conversation and repairs it via _adoptForeignWelcome.
          final placeholder = Conversation(
            id: convoId,
            peerUsername: '',
            peerAccountId: '',
            peerDeviceId: '',
            peerIdentityPubKey: const [],
            messages: const [],
            unreadCount: 0,
            kind: ConversationKind.group,
            groupName: 'New group',
            members: const [],
            cryptoMode: CryptoMode.mls,
            pending: true,
          );
          _host.setConversation(convoId, placeholder);
          await _host.db.upsertConversation(placeholder);
          _host.notifyHost();
          await _host.ack([env.envelopeId]);
          return;
        }
        if (ex != null && ex.cryptoMode != CryptoMode.mls) {
          final flipped = ex.copyWith(cryptoMode: CryptoMode.mls);
          _host.setConversation(convoId, flipped);
          await _host.db.upsertConversation(flipped);
          try {
            await _host.db.deleteConversationCryptoState(convoId);
          } catch (_) {/* none existed */}
          _host.notifyHost();
        }
        await _host.ack([env.envelopeId]);
        return;
      }
      groupId = adopted;
    }
    if (groupId != convoId) {
      // ignore: avoid_print
      print(
        'mls_welcome: CoreCrypto groupId $groupId != wire conversationId '
        '$convoId; trusting CoreCrypto',
      );
    }
    // A group application message that raced ahead of this Welcome (or whose
    // Welcome previously failed) leaves an unknown-peer 1:1 stub under the
    // group id (see _appendUnknownPeerEnvelope). copyWith can't change `kind`,
    // so the flip branch below would strand it as a peerless 1:1 forever
    // ("Can't reply — this sender couldn't be identified"). Rebuild it as a
    // proper group-kind conversation instead. Its stub messages are dropped:
    // they're undecryptable "[encrypted message]" rows whose envelopes are
    // still unacked server-side, so they redeliver and decrypt properly now
    // that the group state exists.
    final upgradeStubToGroup = existing != null &&
        convoId.startsWith('group:') &&
        _isUnknownPeerPlaceholder(existing);
    if (existing != null && !upgradeStubToGroup) {
      if (existing.cryptoMode != CryptoMode.mls) {
        // Flip to MLS; drop orphaned legacy ratchet state.
        final updated = existing.copyWith(cryptoMode: CryptoMode.mls);
        _host.setConversation(convoId, updated);
        await _host.db.upsertConversation(updated);
        try {
          await _host.db.deleteConversationCryptoState(convoId);
        } catch (_) {}
        _host.notifyHost();
      }
      // Already MLS — Welcome is a re-add scenario; nothing else to do.
    } else if (convoId.startsWith('group:')) {
      // Group Welcome: group state exists, but the human name + roster arrive
      // separately in a `group_info` application message. Create a group-kind
      // conversation NOW so the next application message renders in a group.
      // Mark it `pending` (a group invite) UNLESS the Welcome came from one of
      // OUR OWN devices (a sibling/adder pulling this newly-linked device in →
      // auto-join, no accept/reject prompt).
      final selfSync = _deviceCache.isMyDevice(env.senderDeviceId, myDeviceId);
      final placeholder = Conversation(
        id: convoId,
        peerUsername: '',
        peerAccountId: '',
        peerDeviceId: '',
        peerIdentityPubKey: const [],
        messages: const [],
        unreadCount: 0,
        kind: ConversationKind.group,
        groupName: 'New group',
        members: const [],
        cryptoMode: CryptoMode.mls,
        pending: !selfSync,
      );
      _host.setConversation(convoId, placeholder);
      await _host.db.upsertConversation(placeholder);
      if (upgradeStubToGroup) {
        // The replaced 1:1 stub was ratchet-mode; drop any orphaned state.
        try {
          await _host.db.deleteConversationCryptoState(convoId);
        } catch (_) {/* none existed */}
      }
      _host.notifyHost();
    } else {
      // Unknown 1:1: the Welcome is processed (group state exists), only the
      // peer's identity is missing. Resolve the sender so the chat shows a real
      // @username; a SELF-SYNCED Welcome carries OUR OWN senderDeviceId, so
      // derive the peer from the conversation id instead.
      final session = await _sessions.current();
      final myAccountId = session?.accountId;
      final selfSync = _deviceCache.isMyDevice(env.senderDeviceId, myDeviceId);

      var peerUsername = 'unknown';
      var peerAccountId = '';
      var peerDeviceId = env.senderDeviceId;
      List<int> peerIdentityPubKey = const [];
      List<int> peerX25519PubKey = const [];
      var pending = true;

      if (selfSync && myAccountId != null) {
        peerAccountId = _peerAccountFromOneToOneId(convoId, myAccountId);
        peerDeviceId = '';
        pending = false;
        if (peerAccountId.isNotEmpty) {
          try {
            final account = await _api.lookupAccountById(peerAccountId);
            peerUsername = account.username;
            peerIdentityPubKey = account.identityPubKey;
            peerX25519PubKey = account.x25519PubKey;
            peerDeviceId = account.deviceId ?? '';
            _recordPeerDisplayName(account);
          } catch (_) {/* offline — name stays 'unknown', fills in later */}
        }
      } else {
        try {
          final account =
              await _api.lookupAccountByDevice(env.senderDeviceId);
          peerUsername = account.username;
          peerAccountId = account.accountId;
          peerIdentityPubKey = account.identityPubKey;
          peerX25519PubKey = account.x25519PubKey;
          _recordPeerDisplayName(account);
        } catch (_) {/* keep placeholder values */}
      }
      final placeholder = Conversation(
        id: convoId,
        peerUsername: peerUsername,
        peerAccountId: peerAccountId,
        peerDeviceId: peerDeviceId,
        peerIdentityPubKey: peerIdentityPubKey,
        peerX25519PubKey: peerX25519PubKey,
        messages: const [],
        unreadCount: 0,
        cryptoMode: CryptoMode.mls,
        pending: pending,
      );
      _host.setConversation(convoId, placeholder);
      await _host.db.upsertConversation(placeholder);
      _host.notifyHost();
    }
    // The Welcome is consumed — ack so it never replays (a replayed Welcome
    // would hit the collision branch and could wipe the advanced group).
    await _host.ack([env.envelopeId]);
  }

  /// Decrypts an MLS application message + appends it (or handles self-removal /
  /// drives split-brain re-establishment on failure).
  Future<void> onApplication(wire.Envelope env, String myDeviceId) async {
    final convoId = env.conversationId;
    // A redelivery of an envelope we ALREADY decrypted (its ack never landed).
    // CoreCrypto will refuse to decrypt it a second time, and that refusal is
    // indistinguishable from real split brain — three in a row would tear down a
    // perfectly healthy group and rebuild it, stranding whatever was in flight.
    // Ack it away without touching the group or the failure streak.
    if (await _processedLog.contains(env.envelopeId)) {
      await _host.ack([env.envelopeId]);
      return;
    }
    final convo = _host.conversation(convoId);
    // Unknown peer — try to auto-resolve, else surface a placeholder (no ack).
    // MLS-mode placeholders are excluded: their group state can decrypt this
    // even when the sender can't be identified.
    if (convo == null ||
        (_isUnknownPeerPlaceholder(convo) &&
            convo.cryptoMode == CryptoMode.ratchet)) {
      await _appendUnknownPeerEnvelope(env);
      return;
    }
    if (convo.cryptoMode != CryptoMode.mls) {
      // Sender is on MLS but our row says ratchet (often a rejected request
      // coming back). If the group still opens, adopt it; else re-establish.
      try {
        await _crypto.currentEpoch(convoId);
      } catch (_) {
        // ignore: avoid_print
        print('inbound mls_application for ratchet-mode convo $convoId; dropping');
        // We hold NO group (e.g. restored from recovery phrase, wiping the MLS
        // store) but the peer keeps sending under the old group — split brain.
        // Feed re-establishment so FUTURE messages decrypt (this one, sealed to
        // the wiped group, is unrecoverable — forward secrecy).
        if (convo.kind == ConversationKind.oneToOne &&
            convo.peerAccountId.isNotEmpty &&
            _senderCouldBePeer(convo, env.senderDeviceId)) {
          // FORCE, don't count. Reaching here means `currentEpoch` threw: we
          // definitively hold NO group for a 1:1 the peer is still sending to.
          // That is not the ambiguous decrypt error a streak exists to filter
          // out — it is unmistakable split brain (thread deleted, device
          // erased, store rebuilt from the recovery phrase), and every further
          // message they seal to their group is unrecoverable until one side
          // re-keys. Waiting for `_mlsReestablishThreshold` bought nothing but
          // a longer outage: measured on-device 2026-08-20, a deleted 1:1 was
          // one-way dead for ~10 minutes and three silently lost messages, and
          // recovered only after BOTH apps were restarted. The cooldown, the
          // `_reestablishing` guard and the `_senderCouldBePeer` DoS gate all
          // still apply, so forcing here cannot storm.
          unawaited(Future(() => maybeReestablish(
              convoId, env.senderDeviceId, myDeviceId,
              force: true)));
        }
        await _boundUndecryptableApp(env.envelopeId);
        return;
      }
      final flipped = convo.copyWith(cryptoMode: CryptoMode.mls);
      _host.setConversation(convoId, flipped);
      await _host.db.upsertConversation(flipped);
      try {
        await _host.db.deleteConversationCryptoState(convoId);
      } catch (_) {/* none existed */}
      _host.notifyHost();
      // Fall through — the group decrypts this envelope below.
    }
    try {
      final r = await _crypto.decryptAndInspect(
        groupId: convoId,
        ciphertext: env.ciphertext,
      );
      // A successful decrypt proves our group matches the sender's — clear any
      // split-brain failure streak (and this envelope's redelivery count), and
      // the discarded-Welcome tally: our group demonstrably IS the live one, so
      // the role rule is converging after all.
      _mlsDecryptFailures.remove(convoId);
      _discardedWelcomes.remove(convoId);
      unawaited(_retryLog.forget(env.envelopeId));
      // CoreCrypto has consumed this message's key: any redelivery can only
      // fail, so remember it (see the guard at the top of this method).
      unawaited(_processedLog.add(env.envelopeId));
      if (r.selfRemoved) {
        await _handleSelfRemoved(env, convoId);
        return;
      }
      if (r.plaintext != null) {
        // Attribute the sender from the MLS credential (cryptographically
        // authenticated) instead of the transport field. Falls back to the
        // transport value if CoreCrypto didn't surface it.
        final authedEnv = r.senderClientId == null
            ? env
            : env.withSenderDeviceId(r.senderClientId!);
        // Authenticate the MLS-verified sender against the expected participants
        // of this 1:1 before rendering. MLS proves SOME group member sent this,
        // but with BASIC credentials the leaf carries only a device id — not the
        // peer's long-term identity — so a group a stranger built (a Welcome
        // hijack) would decrypt fine and misattribute the stranger's message to
        // the peer. Refuse to render a 1:1 message whose authenticated sender is
        // neither one of our own devices nor a registered device of the expected
        // peer account. Only enforced when CoreCrypto surfaced the authenticated
        // id (production always does for application messages; null ⇒ can't
        // authenticate ⇒ don't drop, e.g. test fakes).
        if (r.senderClientId != null &&
            convo.kind == ConversationKind.oneToOne &&
            await _isForeignSender(convo, r.senderClientId!, myDeviceId)) {
          // ignore: avoid_print
          print('mls_application: authenticated sender is not a known device of '
              'the 1:1 peer on $convoId; dropping (possible group hijack)');
          await _host.ack([env.envelopeId]);
          return;
        }
        await _appender.append(
          env: authedEnv,
          myDeviceId: myDeviceId,
          plaintext: r.plaintext!,
        );
      } else {
        // plaintext is null: ack here before epoch update since the appender
        // is skipped (it normally acks).
        await _host.ack([env.envelopeId]);
      }
      // Update epoch if changed.
      if (r.newEpoch != null && convo.mlsEpoch != r.newEpoch) {
        await _host.db
            .updateConversationGroupFields(convoId, mlsEpoch: r.newEpoch);
        final epochUpdated =
            _host.conversation(convoId)?.copyWith(mlsEpoch: r.newEpoch);
        if (epochUpdated != null) {
          _host.setConversation(convoId, epochUpdated);
          _host.notifyHost();
        }
      }
    } catch (e) {
      // log + drop; common on replay, malformed payload, etc.
      // ignore: avoid_print
      print('mls_application decrypt error for convo $convoId: $e; dropping');
      // Repeated failures from a real peer mean our group diverged (split
      // brain). Count the streak; on the threshold, kick off re-establishment.
      // Only a plausible PEER device drives this — an outsider spraying
      // undecryptable envelopes with unknown/foreign sender ids must not be able
      // to force repeated group teardown + re-migration (a remote DoS).
      if (_senderCouldBePeer(convo, env.senderDeviceId)) {
        // An UNKNOWN GROUP is definitive rather than a streak candidate:
        // CoreCrypto is saying the group this envelope names does not exist
        // here, so no amount of retrying will decrypt it. Rebuild at once, and
        // keep the counting path for the genuinely ambiguous failures (epoch
        // races, replays, malformed payloads) that a single occurrence must
        // never be allowed to tear a healthy group down over.
        // ...and so is "we discarded their Welcome, and now we cannot read
        // them". Each half alone is ambiguous — a discarded Welcome is the
        // normal collision outcome, and a single decrypt error can be an epoch
        // race — but TOGETHER they can only mean the group we chose to keep is
        // the one that does not work. Waiting for the streak here is what
        // stalled the leader on-device 2026-08-20: it acked the peer's rebuild
        // Welcome, kept its own group, and then sat unable to decrypt anything
        // they sent, while the peer's cooldown held back the second Welcome
        // that `_discardedWelcomes` needs to make it yield.
        final discardedTheirRebuild = (_discardedWelcomes[convoId] ?? 0) > 0;
        if (e is MlsUnknownGroupException || discardedTheirRebuild) {
          unawaited(Future(() => maybeReestablish(
              convoId, env.senderDeviceId, myDeviceId,
              force: true)));
        } else {
          _mlsDecryptFailures[convoId] =
              (_mlsDecryptFailures[convoId] ?? 0) + 1;
          unawaited(Future(
              () => maybeReestablish(convoId, env.senderDeviceId, myDeviceId)));
        }
      }
      // ...and bound this envelope's redelivery (sealed to a dead epoch).
      await _boundUndecryptableApp(env.envelopeId);
    }
  }

  /// Processes an MLS handshake message so CoreCrypto's group state advances.
  /// No plaintext to render.
  Future<void> onHandshake(wire.Envelope env) async {
    final convoId = env.conversationId;
    final convo = _host.conversation(convoId);
    if (convo == null || convo.cryptoMode != CryptoMode.mls) {
      // Can't decrypt without group state — drop.
      return;
    }
    try {
      final r = await _crypto.decryptAndInspect(
        groupId: convoId,
        ciphertext: env.ciphertext,
      );
      if (r.selfRemoved) {
        await _handleSelfRemoved(env, convoId);
        return;
      }
      if (r.newEpoch != null && convo.mlsEpoch != r.newEpoch) {
        await _host.db
            .updateConversationGroupFields(convoId, mlsEpoch: r.newEpoch);
        final updated =
            _host.conversation(convoId)?.copyWith(mlsEpoch: r.newEpoch);
        if (updated != null) {
          _host.setConversation(convoId, updated);
          _host.notifyHost();
        }
      }
      await _host.ack([env.envelopeId]);
    } catch (_) {/* log + drop */}
  }

  /// Deterministic split-brain re-establishment: wipe the diverged local group,
  /// flip back to ratchet (next send re-migrates from scratch), and carry a
  /// fresh Welcome to the peer via the no-op re-establish control. Rate-limited
  /// + lexicographically ordered (higher id waits for the lower one first). Pass
  /// [force] to skip the failure-count gate (an external trigger).
  Future<void> maybeReestablish(
    String convoId,
    String senderDeviceId,
    String myDeviceId, {
    bool force = false,
  }) async {
    if (force) _mlsDecryptFailures[convoId] = _mlsReestablishThreshold;
    final convo = _host.conversation(convoId);
    if (convo == null || convo.kind != ConversationKind.oneToOne) return;
    if (convo.peerAccountId.isEmpty) return;
    // A copy of our OWN message relayed from a sibling device that we can't
    // decrypt isn't split brain — don't re-key on self-sync.
    if (await _deviceCache.isMyDeviceWarm(senderDeviceId, myDeviceId)) return;

    if ((_mlsDecryptFailures[convoId] ?? 0) < _mlsReestablishThreshold) return;
    if (_reestablishing.contains(convoId)) return;
    final last = _lastReestablish[convoId];
    if (last != null &&
        DateTime.now().difference(last) < _mlsReestablishCooldown) {
      return;
    }
    // Use the convo's primary peer device id (stable) for ordering when known.
    final peerDev =
        convo.peerDeviceId.isNotEmpty ? convo.peerDeviceId : senderDeviceId;
    // WHO goes first must be the same side that [onWelcome] treats as the
    // authority, or the two rules fight: ordering by device id here while
    // [onWelcome] keeps the smaller ACCOUNT's group made the follower rebuild
    // immediately (its device id happened to be lower) while the leader waited,
    // and the leader then discarded every rebuild Welcome it received — an
    // endless Welcome ping-pong that stranded in-flight messages. Observed live
    // 2026-10-27 (Pixel leader, iPhone follower, iPhone's device id lower). The
    // device-id order is only the fallback when the accounts are unknown.
    final myAccountId = (await _sessions.current())?.accountId ?? '';
    final peerAccountId = _peerAccountFromOneToOneId(convoId, myAccountId);
    final waitsForPeer = myAccountId.isNotEmpty && peerAccountId.isNotEmpty
        ? myAccountId.compareTo(peerAccountId) > 0
        : myDeviceId.compareTo(peerDev) > 0;
    if (waitsForPeer) {
      // The follower gives the leader a window to fix it first.
      await Future<void>.delayed(_mlsReestablishGrace);
      // Adopting the peer's re-establishment Welcome resets the streak.
      if ((_mlsDecryptFailures[convoId] ?? 0) < _mlsReestablishThreshold) {
        return;
      }
      if (_reestablishing.contains(convoId)) return;
    }

    // "They switched phones": the peer restored on a NEW device, so our row
    // still addresses the OLD one. Re-establishment would then mint a Welcome
    // and send it to a phone that no longer exists — the rebuild lands
    // nowhere and the thread stays silent with no error anywhere. Resolve the
    // repair BEFORE taking the conversation lock (it may hit the network).
    final repairedDeviceId = await _confirmedPeerDevice(convo, senderDeviceId);

    _reestablishing.add(convoId);
    final startedAt = DateTime.now();
    _lastReestablish[convoId] = startedAt;
    _mlsDecryptFailures[convoId] = 0;
    try {
      // Wipe the diverged local group and flip the convo back to ratchet so the
      // next send migrates it from scratch (fresh createGroup + Welcome).
      var superseded = false;
      await _host.runLocked(convoId, () async {
        // A send rebuilt this group while we waited for the lock
        // (noteLocalRebuild) — its Welcome already repairs the peer.
        if (!identical(_lastReestablish[convoId], startedAt)) {
          superseded = true;
          return;
        }
        final live = _host.conversation(convoId);
        if (live == null || live.cryptoMode != CryptoMode.mls) return;
        try {
          await _crypto.wipeGroup(convoId);
        } catch (_) {/* may already be gone */}
        final reset = live.copyWith(
          cryptoMode: CryptoMode.ratchet,
          peerDeviceId: repairedDeviceId,
        );
        _host.setConversation(convoId, reset);
        await _host.db.upsertConversation(reset);
        try {
          await _host.db.deleteConversationCryptoState(convoId);
        } catch (_) {/* none */}
        _host.notifyHost();
      });
      if (superseded) return;
      // Carry a fresh Welcome to the peer via the no-op re-establish control
      // (it rides the migrator's send path, which migrates a ratchet-mode
      // convo: createGroup + addMember + Welcome + this payload).
      debugPrint('mls: re-establishing diverged group on $convoId');
      // Only the LEADER (smaller account) builds the replacement group. The
      // follower's control goes out on ratchet: the leader sees a text_legacy
      // for a convo it holds as MLS, rebuilds, and the follower adopts that
      // Welcome. A follower that built its own group here collided with the
      // leader's rebuild (two Welcome rounds, the first messages lost) after a
      // delete + re-contact. Unknown account ids keep the old forced rebuild.
      final roleKnown = myAccountId.isNotEmpty && peerAccountId.isNotEmpty;
      final iAmFollower = roleKnown && waitsForPeer;
      await _controlSender.sendControl(
          convoId, const MessageControl.reestablish().encode(),
          forceMigration: !iAmFollower);
    } catch (e) {
      debugPrint('mls re-establish failed on $convoId: $e');
    } finally {
      _reestablishing.remove(convoId);
    }
  }

  /// Returns [senderDeviceId] when it is a device of this 1:1's peer account
  /// that our row does NOT currently address — i.e. the peer moved to a new
  /// phone and we should reply there instead. Null means "leave the row alone".
  ///
  /// SERVER-VERIFIED, deliberately. The caller re-points the conversation and
  /// then mints an MLS Welcome for that device: welcoming a STRANGER's device
  /// into a 1:1 group would hand them every future message in it — the same
  /// hijack `_isForeignSender` refuses to render on the receive side. So a
  /// merely plausible sender is not enough (`_senderCouldBePeer` says yes on an
  /// empty cache); we need the device to be positively attributed to the peer
  /// account. An offline/unknown lookup returns null and the row stands.
  Future<String?> _confirmedPeerDevice(
      Conversation convo, String senderDeviceId) async {
    if (senderDeviceId.isEmpty ||
        senderDeviceId == convo.peerDeviceId ||
        convo.peerAccountId.isEmpty) {
      return null;
    }
    for (final d in _deviceCache.peerDevices(convo.peerAccountId)) {
      if (d.deviceId == senderDeviceId) return senderDeviceId;
    }
    // Not in the cache — which may simply be stale (the peer registered this
    // device after we last looked). Ask the server, which is authoritative and
    // excludes revoked devices.
    try {
      final account = await _api.lookupAccountByDevice(senderDeviceId);
      if (account.accountId == convo.peerAccountId) return senderDeviceId;
    } catch (_) {/* offline / unknown device — don't touch the row */}
    return null;
  }

  /// Handles inbound notification that we were removed from a group: injects a
  /// local `you_were_removed` system message, clears membership, and acks.
  Future<void> _handleSelfRemoved(wire.Envelope env, String convoId) async {
    final convo = _host.conversation(convoId);
    if (convo == null) return;
    // Determine "by" from the envelope's sender, looked up in current members.
    // Fall back to 'admin' if not in our projection.
    final byMatches =
        convo.members.where((m) => m.deviceId == env.senderDeviceId);
    final by = byMatches.isEmpty ? 'admin' : byMatches.first.username;

    final now = DateTime.now().toUtc();
    final ev = SystemEvent.youWereRemoved(by: by);
    final synthetic = ChatMessage(
      envelopeId: 'local-syn-removed-${env.envelopeId}',
      conversationId: convoId,
      senderDeviceId: 'system',
      body: ev.toJsonString(),
      serverTs: now,
      mine: false,
      kind: MessageKind.system,
    );

    // Append the system message and clear the membership (we're out).
    final updated = Conversation(
      id: convo.id,
      peerUsername: convo.peerUsername,
      peerAccountId: convo.peerAccountId,
      peerDeviceId: convo.peerDeviceId,
      peerIdentityPubKey: convo.peerIdentityPubKey,
      peerX25519PubKey: convo.peerX25519PubKey,
      messages: [...convo.messages, synthetic],
      unreadCount: convo.unreadCount + 1,
      verified: convo.verified,
      hasMoreOlderMessages: convo.hasMoreOlderMessages,
      cryptoMode: convo.cryptoMode,
      needsReestablishment: convo.needsReestablishment,
      kind: convo.kind,
      groupName: convo.groupName,
      groupAvatar: convo.groupAvatar,
      members: const [], // empty membership => composer disabled
      mlsEpoch: null,
    );
    _host.setConversation(convoId, updated);
    await _host.db.upsertConversation(updated);
    await _host.db.upsertMessages(convoId, [synthetic]);
    await _host.db.deleteGroupMembersForConversation(convoId);
    _host.notifyHost();
    await _host.ack([env.envelopeId]); // ack the Commit so it doesn't replay
  }

  /// Whether [senderClientId] (an MLS-authenticated device id) is NOT an
  /// expected participant of the 1:1 [convo] — neither one of our own devices
  /// nor a registered device of the peer account. Returns false (not foreign)
  /// whenever we can't be sure (no peer directory available), so a transient
  /// offline lookup never drops a legitimate message. Warms the peer directory
  /// once (rate-limited) before concluding a sender is foreign.
  Future<bool> _isForeignSender(
      Conversation convo, String senderClientId, String myDeviceId) async {
    if (senderClientId.isEmpty) return false;
    if (senderClientId == myDeviceId) return false;
    if (senderClientId == convo.peerDeviceId) return false;
    if (await _deviceCache.isMyDeviceWarm(senderClientId, myDeviceId)) {
      return false;
    }
    if (_peerDirectoryContains(convo, senderClientId)) return false;
    // Unknown in the cached directory — refresh it once per window, then re-check
    // (covers a peer that linked a new device we haven't learned about yet).
    final last = _lastPeerDirWarm[convo.id];
    if (last == null ||
        DateTime.now().difference(last) > const Duration(seconds: 30)) {
      _lastPeerDirWarm[convo.id] = DateTime.now();
      if (convo.peerUsername.isNotEmpty) {
        try {
          _recordPeerDisplayName(await _api.lookupAccount(convo.peerUsername));
        } catch (_) {/* offline — can't verify; treated as not-foreign below */}
      }
      if (_peerDirectoryContains(convo, senderClientId)) return false;
    }
    // Still unknown. Only conclude "foreign" when we hold an actual (non-empty)
    // peer directory to enumerate against; with none (offline / lookup failed)
    // we can't be sure the peer doesn't own this device, so don't drop. In
    // production the warm above populates the directory, so an established
    // conversation reaches this with a real device list.
    if (_deviceCache.peerDevices(convo.peerAccountId).isEmpty) return false;
    return true;
  }

  /// Whether [deviceId] is a registered device of [convo]'s peer account, from
  /// the cached directory.
  bool _peerDirectoryContains(Conversation convo, String deviceId) {
    for (final d in _deviceCache.peerDevices(convo.peerAccountId)) {
      if (d.deviceId == deviceId) return true;
    }
    return false;
  }

  /// Whether [deviceId] could plausibly be the 1:1 peer (so a decrypt failure
  /// from it may reflect genuine group divergence worth re-establishing). True
  /// when it matches the peer's primary/known devices, or when we hold NO peer
  /// directory to judge against (don't suppress genuine recovery on a cold
  /// cache). A device that is definitively NOT the peer returns false so it
  /// can't drive re-establishment churn.
  bool _senderCouldBePeer(Conversation convo, String deviceId) {
    if (deviceId.isEmpty) return true;
    if (deviceId == convo.peerDeviceId) return true;
    final known = _deviceCache.peerDevices(convo.peerAccountId);
    if (known.isEmpty) return true;
    for (final d in known) {
      if (d.deviceId == deviceId) return true;
    }
    return false;
  }

  /// Counts one decrypt failure for an MLS application [envelopeId] and, once it
  /// has failed [_maxUndecryptableRedeliveries] times, acks+drops it so it stops
  /// redelivering forever. Best-effort.
  Future<void> _boundUndecryptableApp(String envelopeId) async {
    // DURABLE count: this used to live in an in-memory map that reset on every
    // app start, and a poison envelope fails exactly ONCE PER LAUNCH — so the
    // threshold was unreachable and the envelope was re-fetched and
    // re-decrypted on every single launch, forever. Measured on-device
    // 2026-08-22: 24 such envelopes were burning ~900ms of a 1.4s catchup, a
    // tax that grows as more poison accumulates.
    final n = await _retryLog.recordFailure(envelopeId);
    if (n >= _maxUndecryptableRedeliveries) {
      await _retryLog.forget(envelopeId);
      try {
        await _host.ack([envelopeId]);
      } catch (_) {/* best-effort; retried next reconnect */}
    }
  }
}
