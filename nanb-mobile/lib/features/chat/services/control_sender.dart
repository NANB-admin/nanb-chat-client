import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../../core/crypto/conversation_crypto_state.dart';
import '../../../core/crypto/crypto_bridge.dart';
import '../../../core/models/envelope.dart' as wire;
import '../../../core/network/api_client.dart';
import '../../../core/push/push_kind.dart';
import '../../onboarding/session_repository.dart';
import '../mls_migrator.dart';
import '../models/control_migration_outcome.dart';
import '../models/conversation.dart';
import '../models/conversation_kind.dart';
import '../models/crypto_mode.dart';
import 'device_cache.dart';
import 'notifier_service_host.dart';
import 'ratchet_core.dart';

/// Sends a control payload (receipt / unsend / reaction / pin / privacy / call
/// signal / request-decision / access-key) through the same E2EE pipeline as a
/// normal message but without an on-screen bubble: [sendControl] to the peer
/// (auto-migrating ratchet→MLS on first send, lock-stepping the ratchet), and
/// [sendSelfControl] to THIS account's other devices (self-sync). Extracted from
/// `ConversationsNotifier`; the universal submit chokepoint stays on the notifier
/// (reached via `host.submit`).
class ControlSender {
  ControlSender({
    required NotifierServiceHost host,
    required CryptoBridge crypto,
    required ApiClient api,
    required SessionRepository sessions,
    required RatchetCore ratchetCore,
    required DeviceCache deviceCache,
    required int? Function() contentTtlSeconds,
    Future<ControlMigrationOutcome> Function(
      Conversation convo,
      String body, {
      required bool force,
      required String pushKind,
    })? migrateMultiDevice,
  })  : _migrateMultiDevice = migrateMultiDevice,
        _host = host,
        _crypto = crypto,
        _api = api,
        _sessions = sessions,
        _ratchetCore = ratchetCore,
        _deviceCache = deviceCache,
        _contentTtlSeconds = contentTtlSeconds;

  final NotifierServiceHost _host;
  final CryptoBridge _crypto;
  final ApiClient _api;
  final SessionRepository _sessions;
  final RatchetCore _ratchetCore;
  final DeviceCache _deviceCache;
  final int? Function() _contentTtlSeconds;

  /// Builds the all-devices MLS group for a multi-device 1:1 still on ratchet
  /// and delivers the control inside it. Null in tests that don't need it.
  final Future<ControlMigrationOutcome> Function(
    Conversation convo,
    String body, {
    required bool force,
    required String pushKind,
  })? _migrateMultiDevice;

  /// Encrypts + submits a control [body] to the peer of [conversationId] through
  /// the same ratchet/MLS path as a normal message (no on-screen bubble); the
  /// receiver detects the control and drops it. Auto-migrates ratchet→MLS on the
  /// first send when the peer has key packages.
  ///
  /// Addressing on an MLS 1:1 (one ciphertext opens on every member device):
  /// [toDeviceId] targets that one peer device; [allPeerDevices] targets every
  /// device in the peer's directory. Otherwise — and always on ratchet, whose
  /// ciphertext is per-device — the row's `peerDeviceId`.
  ///
  /// On a GROUP the control goes to every member device except this one (our own
  /// other devices are members, so they receive it too). [onSealed] fires once
  /// the control is encrypted and the live MLS group is no longer needed, while
  /// the network submit is still ahead — see `GroupDisbandService`.
  Future<void> sendControl(String conversationId, String body,
      {String? pushKind,
      bool forceMigration = false,
      String? toDeviceId,
      bool allPeerDevices = false,
      void Function()? onSealed}) async {
    // A control envelope carries no user-visible content, so absent an explicit
    // hint (e.g. a call invite's 'call') it sends as 'silent': the server skips
    // the offline wakeup and a woken background isolate suppresses the banner.
    // Without this, opening a chat (which fires a read receipt) buzzed the peer
    // with a phantom "new message".
    final effectivePushKind = pushKind ?? PushKind.silent;
    final convo = _host.conversation(conversationId);
    if (convo == null) return;
    if (convo.peerX25519PubKey.isEmpty &&
        convo.cryptoMode == CryptoMode.ratchet) {
      return;
    }
    // Outside the lock: a cold directory costs one lookup, and the fallback
    // (the row's possibly-stale peerDeviceId) is exactly what rang dead phones.
    final firstContactOnRatchet = convo.kind == ConversationKind.oneToOne &&
        convo.cryptoMode == CryptoMode.ratchet;
    if (allPeerDevices || firstContactOnRatchet) {
      // A ratchet 1:1 may be about to migrate: we must know ALL the peer's
      // devices first, or the group is built without the ones we can't see.
      await _warmPeerDirectory(convo.peerAccountId, convo.peerUsername);
    }
    await _host.runLocked(conversationId, () async {
      final live = _host.conversation(conversationId) ?? convo;
      final session = await _sessions.current();
      final myAccountId = session?.accountId ?? '';
      var allowMigration = true;
      final migrateMultiDevice = _migrateMultiDevice;
      if (migrateMultiDevice != null) {
        final outcome = await migrateMultiDevice(live, body,
            force: forceMigration, pushKind: effectivePushKind);
        if (outcome == ControlMigrationOutcome.migrated) {
          // The multi-device migration already delivered the control.
          onSealed?.call();
          return;
        }
        allowMigration = outcome != ControlMigrationOutcome.deferToSibling;
      }
      ConversationCryptoState? pendingRatchetState;
      final migrator = MlsMigrator(
        bridge: _crypto,
        apiClient: _api,
        myAccountId: myAccountId,
        legacyEncryptOnRatchet: (c, pt) => _ratchetCore.encryptForConvo(
          c,
          pt,
          onStateAdvanced: (s) => pendingRatchetState = s,
        ),
      );
      // A re-establishment forces migration so a stranded follower (which the
      // deterministic-migration rule would otherwise keep on ratchet) can
      // rebuild the group and carry a fresh Welcome to the peer.
      final migResult = await migrator.encryptForSend(
        convo: live,
        plaintext: utf8.encode(body),
        forceMigration: forceMigration,
        allowMigration: allowMigration,
      );
      onSealed?.call();
      if (migResult.welcomeBytes != null) {
        await _api.submitMessage(SubmitMessagePayload(
          conversationId: conversationId,
          envelopeType: wire.EnvelopeType.mlsWelcome,
          recipientAccountId: live.peerAccountId,
          recipientDeviceId: migResult.welcomeRecipientDeviceId!,
          ciphertext: migResult.welcomeBytes!,
          // Protocol-only envelope — never raise a banner on the peer.
          pushKind: PushKind.silent,
        ));
      }
      // Control messages ride the warm WebSocket too (same chokepoint as content
      // sends, HTTP fallback when the socket is down). Awaiting the WS ack inside
      // the convo lock is safe: the ack isn't an envelope, so it never re-enters
      // the receive path or re-takes this lock.
      final targets = migResult.envelopeType == wire.EnvelopeType.mlsApplication
          ? _peerTargets(live.peerAccountId, live.peerDeviceId,
              toDeviceId: toDeviceId, allPeerDevices: allPeerDevices)
          : [live.peerDeviceId];
      final recipients = live.kind == ConversationKind.group
          ? _groupRecipients(live, session?.deviceId)
          : [
              for (final id in targets)
                (accountId: live.peerAccountId, deviceId: id),
            ];
      // A group of one (we are the only device) has nobody to tell.
      if (live.kind == ConversationKind.group && recipients.isEmpty) return;
      Object? firstError;
      var delivered = false;
      for (final r in recipients) {
        try {
          await _host.submit(SubmitMessagePayload(
            conversationId: conversationId,
            envelopeType: migResult.envelopeType,
            recipientAccountId: r.accountId,
            recipientDeviceId: r.deviceId,
            ciphertext: migResult.ciphertext,
            ttlSeconds: _contentTtlSeconds(),
            pushKind: effectivePushKind,
          ));
          delivered = true;
        } catch (e) {
          // One dead device (revoked, reinstalled) must not sink the others.
          firstError ??= e;
        }
      }
      if (!delivered) throw firstError ?? StateError('no control recipient');
      if (pendingRatchetState != null) {
        await _host.db.saveConversationCryptoState(pendingRatchetState!);
      }
      if (migResult.newMode == CryptoMode.mls &&
          live.cryptoMode == CryptoMode.ratchet) {
        final migrated = live.copyWith(cryptoMode: CryptoMode.mls);
        _host.setConversation(conversationId, migrated);
        await _host.db.upsertConversation(migrated);
        await _host.db.deleteConversationCryptoState(conversationId);
        _host.notifyHost();
      }
    });
  }

  Future<void> _warmPeerDirectory(
      String peerAccountId, String peerUsername) async {
    // Refresh when the directory is cold OR stale: a peer who linked a device
    // after we cached their list would otherwise never be addressed (same rule
    // as the MLS content fan-out). Bounded, and a failure keeps the cached list.
    final cached = _deviceCache.peerDevices(peerAccountId);
    if (cached.isNotEmpty && !_deviceCache.peerDevicesStale(peerAccountId)) {
      return;
    }
    if (peerUsername.isEmpty) return;
    try {
      final account = await _api
          .lookupAccount(peerUsername)
          .timeout(const Duration(seconds: 5));
      if (account.accountId == peerAccountId && account.devices.isNotEmpty) {
        _deviceCache.setPeerDevices(peerAccountId, account.devices);
      }
    } catch (_) {/* offline/slow — keep the cached list, else peerDeviceId */}
  }

  /// Every member device of [group] except this one.
  List<({String accountId, String deviceId})> _groupRecipients(
          Conversation group, String? myDeviceId) =>
      [
        for (final m in group.members)
          if (m.deviceId != myDeviceId)
            (accountId: m.accountId, deviceId: m.deviceId),
      ];

  /// The peer device(s) an MLS control goes to — see [sendControl].
  List<String> _peerTargets(String peerAccountId, String peerDeviceId,
      {String? toDeviceId, required bool allPeerDevices}) {
    if (toDeviceId != null && toDeviceId.isNotEmpty) return [toDeviceId];
    if (allPeerDevices) {
      final directory = [
        for (final d in _deviceCache.peerDevices(peerAccountId)) d.deviceId,
      ];
      if (directory.isNotEmpty) return directory;
    }
    return [peerDeviceId];
  }

  /// Sends a control [body] to THIS account's OTHER devices only (never the
  /// peer) — self-syncs a decision/reaction/pin so a linked device converges.
  /// No-op on a single-device account.
  ///
  /// [onSealed] fires once the body is ENCRYPTED on an MLS conversation (the
  /// live group is no longer needed) while the submits are still ahead.
  Future<void> sendSelfControl(String conversationId, String body,
      {void Function()? onSealed}) async {
    final session = await _sessions.current();
    if (session == null) return;
    final myOthers = (await _deviceCache.myDevices())
        .where(
            (d) => d.deviceId != session.deviceId && d.x25519PubKey.isNotEmpty)
        .toList();
    if (myOthers.isEmpty) return;
    if (_host.conversation(conversationId) == null) return;
    await _host.runLocked(conversationId, () async {
      final live = _host.conversation(conversationId);
      if (live == null) return;
      if (live.cryptoMode == CryptoMode.mls) {
        try {
          final ct = await _crypto.encrypt(
              groupId: conversationId, plaintext: utf8.encode(body));
          onSealed?.call();
          for (final d in myOthers) {
            try {
              await _host.submit(SubmitMessagePayload(
                conversationId: conversationId,
                envelopeType: wire.EnvelopeType.mlsApplication,
                recipientAccountId: session.accountId,
                recipientDeviceId: d.deviceId,
                ciphertext: ct,
                // Self-sync of a control event — must not buzz my own device.
                pushKind: PushKind.silent,
              ));
            } catch (e) {
              debugPrint('self-control to ${d.deviceId} failed: $e');
            }
          }
        } catch (e) {
          debugPrint('self-control mls encrypt failed: $e');
        }
      } else {
        final targets = [
          for (final d in myOthers)
            RatchetFanoutTarget(
              accountId: session.accountId,
              deviceId: d.deviceId,
              ratchetKey: d.deviceId,
              x25519: d.x25519PubKey,
            ),
        ];
        try {
          await _ratchetCore.fanout(conversationId, body, targets,
              pushKind: PushKind.silent);
        } catch (e) {
          debugPrint('self-control ratchet fanout failed: $e');
        }
      }
    });
  }
}
