import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../../core/crypto/crypto_bridge.dart';
import '../../../core/models/envelope.dart' as wire;
import '../../../core/network/api_client.dart';
import '../../../core/push/push_kind.dart';
import '../../../core/secure_storage/secure_storage.dart';
import '../../onboarding/session_repository.dart';
import '../models/chat_message.dart';
import '../models/conversation.dart';
import '../models/conversation_kind.dart';
import '../models/group_member.dart';
import '../models/group_recovery_message.dart';
import '../models/message_kind.dart';
import '../models/system_event.dart';
import 'notifier_service_host.dart';
import 'resend_wire_body.dart';

/// Gets a device that lost a group's MLS state back into that group, and re-sends
/// what it missed.
///
/// A 1:1 can simply be rebuilt, but a group can't: rebuilding would fork it for
/// every other member. So a device whose group is gone used to be out for good:
/// it couldn't read or send, and adding it back failed with "already in group".
///
/// The stranded device asks the other member devices over sealed, signed messages
/// ([GroupRecoveryMessage]). One device then removes its old leaf and adds it back
/// with a fresh key package. Devices are ranked, so a lower-ranked one only acts
/// if the epoch hasn't moved by its turn, meaning nobody ahead of it did. Once back,
/// the device asks each member to re-send its own messages from after the last one
/// it holds; the receiver dedups them by client message id.
///
/// Who may ask is limited to devices on the roster, and a member is never sent
/// anything from before it joined. A device linked after onboarding signs with its
/// own key, which the roster doesn't record, so that case relies on the server
/// confirming the device belongs to that member. A forged request can only cause a
/// rate-limited re-key: the Welcome is sealed to the named device's key package.
class GroupRecoveryService {
  GroupRecoveryService({
    required NotifierServiceHost host,
    required CryptoBridge crypto,
    required ApiClient api,
    required SessionRepository sessions,
    required SecureStorage storage,
    required void Function() onRejoined,
    Duration helperStep = const Duration(seconds: 20),
    DateTime Function()? clock,
  })  : _host = host,
        _crypto = crypto,
        _api = api,
        _sessions = sessions,
        _storage = storage,
        _onRejoined = onRejoined,
        _helperStep = helperStep,
        _clock = clock ?? (() => DateTime.now().toUtc());

  final NotifierServiceHost _host;
  final CryptoBridge _crypto;
  final ApiClient _api;
  final SessionRepository _sessions;
  final SecureStorage _storage;
  final void Function() _onRejoined;
  final Duration _helperStep;
  final DateTime Function() _clock;

  static const String storageKey = 'mls.groups_awaiting_rejoin';
  static const Duration _requestCooldown = Duration(minutes: 10);
  static const Duration _helpCooldown = Duration(minutes: 10);
  static const Duration _maxRequestAge = Duration(days: 7);
  static const Duration _resyncWindow = Duration(days: 14);
  static const int _maxResyncMessages = 50;

  final Map<String, DateTime> _lastRequest = {};
  final Map<String, DateTime> _lastHelped = {};
  final Map<String, Timer> _helperTimers = {};

  /// This device holds no usable state for [groupId]: ask to be re-added.
  /// Rate-limited; never throws.
  Future<void> requestRejoin(String groupId) async {
    try {
      final convo = _host.conversation(groupId);
      if (convo == null ||
          convo.kind != ConversationKind.group ||
          convo.pending) {
        return;
      }
      final now = _clock();
      final last = _lastRequest[groupId];
      if (last != null && now.difference(last) < _requestCooldown) return;
      _lastRequest[groupId] = now;
      await _setAwaiting(groupId, true);
      await _sendToOthers(convo, GroupRecoveryKind.rejoin);
    } catch (e) {
      debugPrint('group rejoin request failed on $groupId: $e');
    }
  }

  /// This device just joined [groupId] from a Welcome. Asks for what it missed,
  /// but only if it had asked to come back: a brand-new member gets no history.
  /// Never throws.
  Future<void> onJoinedFromWelcome(String groupId) async {
    try {
      if (!await _isAwaiting(groupId)) return;
      await _setAwaiting(groupId, false);
      _lastRequest.remove(groupId);
      final convo = _host.conversation(groupId);
      if (convo != null) {
        await _sendToOthers(convo, GroupRecoveryKind.resync);
      }
      _onRejoined();
    } catch (e) {
      debugPrint('group resync request failed on $groupId: $e');
    }
  }

  /// Handles an inbound [wire.EnvelopeType.groupRecovery]. Never throws.
  Future<void> onEnvelope(wire.Envelope env) async {
    try {
      final message = GroupRecoveryMessage.tryDecode(env.ciphertext);
      if (message == null) return;
      final convo = _host.conversation(message.groupId);
      if (convo == null || convo.kind != ConversationKind.group) return;
      final requester = _rosterRow(convo, message.deviceId);
      if (requester == null) return;
      final myDeviceId = await _host.selfDeviceId();
      if (message.deviceId == myDeviceId) return;
      if (!await _isAuthentic(message, requester)) return;
      final age = _clock().millisecondsSinceEpoch - message.issuedAtMs;
      if (age > _maxRequestAge.inMilliseconds) return;
      switch (message.kind) {
        case GroupRecoveryKind.rejoin:
          await _scheduleRejoinHelp(convo, message, requester, myDeviceId);
        case GroupRecoveryKind.resync:
          await _resendMissed(convo, message, requester, myDeviceId);
      }
    } catch (e) {
      debugPrint('group recovery message failed: $e');
    }
  }

  void dispose() {
    for (final timer in _helperTimers.values) {
      timer.cancel();
    }
    _helperTimers.clear();
  }

  GroupMember? _rosterRow(Conversation convo, String deviceId) {
    for (final m in convo.members) {
      if (m.deviceId == deviceId) return m;
    }
    return null;
  }

  Future<bool> _isAuthentic(
      GroupRecoveryMessage message, GroupMember requester) async {
    if (await message.verify(requester.identityPubKey)) return true;
    // A linked device has its own key, which the roster doesn't record.
    try {
      final account = await _api.lookupAccountByDevice(message.deviceId);
      return account.accountId == requester.accountId;
    } catch (_) {
      return false;
    }
  }

  Future<void> _sendToOthers(Conversation convo, GroupRecoveryKind kind) async {
    final session = await _sessions.current();
    final identity = await _crypto.currentIdentity();
    if (session == null || identity == null) return;
    final issuedAtMs = _clock().millisecondsSinceEpoch;
    final sinceMs = _newestMessageMs(convo);
    final signature = await _crypto.signWithIdentity(
      identity,
      GroupRecoveryMessage.signingBytes(
        kind: kind,
        groupId: convo.id,
        deviceId: session.deviceId,
        sinceMs: sinceMs,
        issuedAtMs: issuedAtMs,
      ),
    );
    final body = GroupRecoveryMessage(
      kind: kind,
      groupId: convo.id,
      deviceId: session.deviceId,
      sinceMs: sinceMs,
      issuedAtMs: issuedAtMs,
      signature: signature,
    ).encode();
    for (final m in convo.members) {
      if (m.deviceId == session.deviceId) continue;
      try {
        await _host.submit(SubmitMessagePayload(
          conversationId: convo.id,
          envelopeType: wire.EnvelopeType.groupRecovery,
          recipientAccountId: m.accountId,
          recipientDeviceId: m.deviceId,
          ciphertext: body,
          pushKind: PushKind.silent,
        ));
      } catch (e) {
        debugPrint('group recovery to ${m.deviceId} failed: $e');
      }
    }
  }

  int _newestMessageMs(Conversation convo) {
    var newest = 0;
    for (final m in convo.messages) {
      final ms = m.serverTs.millisecondsSinceEpoch;
      if (ms > newest) newest = ms;
    }
    return newest;
  }

  Future<void> _scheduleRejoinHelp(
    Conversation convo,
    GroupRecoveryMessage message,
    GroupMember requester,
    String myDeviceId,
  ) async {
    final key = '${convo.id}|${message.deviceId}';
    final now = _clock();
    final last = _lastHelped[key];
    if (last != null && now.difference(last) < _helpCooldown) return;
    if (_helperTimers.containsKey(key)) return;
    // Throws if this device doesn't hold the group either, so it can't help.
    final epochAtRequest = await _crypto.currentEpoch(convo.id);
    final helpers = [
      for (final m in convo.members)
        if (m.deviceId != message.deviceId) m.deviceId,
    ]..sort();
    final rank = helpers.indexOf(myDeviceId);
    if (rank < 0) return;
    _helperTimers[key] = Timer(_helperStep * rank, () {
      _helperTimers.remove(key);
      unawaited(_readd(convo.id, requester, epochAtRequest, key));
    });
  }

  Future<void> _readd(String groupId, GroupMember requester, int epochAtRequest,
      String helpKey) async {
    try {
      await _host.runLocked(groupId, () async {
        final live = _host.conversation(groupId);
        if (live == null) return;
        // It moved: a device ranked ahead of us has already done this.
        if (await _crypto.currentEpoch(groupId) != epochAtRequest) return;
        final packages = await _api.lookupDeviceKeyPackages(requester.username);
        final package = packages
            .where((p) => p.deviceId == requester.deviceId)
            .firstOrNull;
        if (package == null) return;
        _lastHelped[helpKey] = _clock();

        final commits = <List<int>>[];
        try {
          commits.add(await _crypto.removeMember(
              groupId: groupId, targetDeviceId: requester.deviceId));
        } catch (e) {
          // A failed Welcome last time leaves no old leaf to remove.
          debugPrint('group rejoin: no old leaf for ${requester.deviceId}: $e');
        }
        final added = await _crypto.addMember(
            groupId: groupId, peerKeyPackage: package.keyPackage);
        commits.add(added.commit);

        final myDeviceId = await _host.selfDeviceId();
        for (final commit in commits) {
          for (final m in live.members) {
            if (m.deviceId == myDeviceId || m.deviceId == requester.deviceId) {
              continue;
            }
            try {
              await _api.submitMessage(SubmitMessagePayload(
                conversationId: groupId,
                envelopeType: wire.EnvelopeType.mlsHandshake,
                recipientAccountId: m.accountId,
                recipientDeviceId: m.deviceId,
                ciphertext: commit,
              ));
            } catch (e) {
              debugPrint('group rejoin: commit to ${m.deviceId} failed: $e');
            }
          }
        }
        await _api.submitMessage(SubmitMessagePayload(
          conversationId: groupId,
          envelopeType: wire.EnvelopeType.mlsWelcome,
          recipientAccountId: requester.accountId,
          recipientDeviceId: requester.deviceId,
          ciphertext: added.welcome,
        ));
        final epoch = await _crypto.currentEpoch(groupId);
        await _host.db.updateConversationGroupFields(groupId, mlsEpoch: epoch);
        _host.setConversation(groupId, live.copyWith(mlsEpoch: epoch));
        _host.notifyHost();
      });
    } catch (e) {
      debugPrint('group rejoin help failed on $groupId: $e');
    }
  }

  /// Re-sends this device's messages from after [message]'s `sinceMs`, to the
  /// requesting device only.
  Future<void> _resendMissed(
    Conversation convo,
    GroupRecoveryMessage message,
    GroupMember requester,
    String myDeviceId,
  ) async {
    final key = 'resync|${convo.id}|${message.deviceId}';
    final now = _clock();
    final last = _lastHelped[key];
    if (last != null && now.difference(last) < _helpCooldown) return;
    _lastHelped[key] = now;

    final sealed = await _host.runLocked(convo.id, () async {
      final live = _host.conversation(convo.id);
      if (live == null) return const <List<int>>[];
      final out = <List<int>>[];
      for (final m in _missedBy(live, message, requester, myDeviceId, now)) {
        final body = buildResendWireBody(m, now: now);
        if (body == null) continue;
        out.add(await _crypto.encrypt(
            groupId: convo.id, plaintext: utf8.encode(body)));
      }
      return out;
    });
    for (final ciphertext in sealed) {
      try {
        await _host.submit(SubmitMessagePayload(
          conversationId: convo.id,
          envelopeType: wire.EnvelopeType.mlsApplication,
          recipientAccountId: requester.accountId,
          recipientDeviceId: requester.deviceId,
          ciphertext: ciphertext,
          pushKind: PushKind.silent,
        ));
      } catch (e) {
        debugPrint('group resync to ${requester.deviceId} failed: $e');
      }
    }
  }

  List<ChatMessage> _missedBy(
    Conversation convo,
    GroupRecoveryMessage message,
    GroupMember requester,
    String myDeviceId,
    DateTime now,
  ) {
    final floorMs = [
      message.sinceMs,
      _joinedAtMs(convo, requester),
      now.subtract(_resyncWindow).millisecondsSinceEpoch,
    ].reduce((a, b) => a > b ? a : b);
    final missed = [
      for (final m in convo.messages)
        if (m.mine &&
            m.senderDeviceId == myDeviceId &&
            !m.failed &&
            (m.outboxId ?? '').isEmpty &&
            m.kind != MessageKind.system &&
            m.serverTs.millisecondsSinceEpoch > floorMs)
          m,
    ]..sort((a, b) => a.serverTs.compareTo(b.serverTs));
    return missed.length <= _maxResyncMessages
        ? missed
        : missed.sublist(missed.length - _maxResyncMessages);
  }

  /// When [member]'s account last joined, from this device's own record, so that
  /// asking can't reveal anything from before it was in the group.
  int _joinedAtMs(Conversation convo, GroupMember member) {
    var joinedAt = 0;
    for (final m in convo.messages) {
      if (m.kind != MessageKind.system) continue;
      final event = SystemEvent.tryDecode(m.body);
      if (event?.kind == SystemEventKind.memberJoined &&
          event?.accountId == member.accountId) {
        final ms = m.serverTs.millisecondsSinceEpoch;
        if (ms > joinedAt) joinedAt = ms;
      }
    }
    return joinedAt;
  }

  Future<Set<String>> _awaiting() async {
    try {
      final raw = await _storage.getString(storageKey);
      if (raw == null || raw.isEmpty) return {};
      return (jsonDecode(raw) as List<dynamic>).cast<String>().toSet();
    } catch (_) {
      return {};
    }
  }

  Future<bool> _isAwaiting(String groupId) async =>
      (await _awaiting()).contains(groupId);

  Future<void> _setAwaiting(String groupId, bool awaiting) async {
    final set = await _awaiting();
    final changed = awaiting ? set.add(groupId) : set.remove(groupId);
    if (changed) await _storage.putString(storageKey, jsonEncode(set.toList()));
  }
}
