import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../../core/crypto/crypto_bridge.dart';
import '../../../core/models/account.dart';
import '../../../core/models/device.dart';
import '../../../core/models/envelope.dart' as wire;
import '../../../core/network/api_client.dart';
import '../../onboarding/session_repository.dart';
import '../models/conversation.dart';
import '../models/conversation_kind.dart';
import '../models/crypto_mode.dart';
import '../models/group_member.dart';
import '../models/group_member_unavailable_exception.dart';
import '../models/member_seed.dart';
import '../models/system_event.dart';
import 'notifier_service_host.dart';

/// Group-creation + membership operations (MLS, spec §10). Bootstraps a new
/// group (createGroup), adds members (addMemberToGroup), and fans the group
/// name + roster to members (broadcastGroupInfo). Group MLS is a distinct
/// concern from 1:1 send/receive; this lifts it out of `ConversationsNotifier`.
///
/// Group sends use `_api.submitMessage` DIRECTLY (Welcomes/Commits/roster are
/// addressed per recipient device and are not sealed), so this needs the api +
/// crypto + session injected, the [NotifierServiceHost] for the live
/// conversation map / db / lock / notify, and a few notifier helpers as
/// callbacks.
class GroupManager {
  GroupManager({
    required NotifierServiceHost host,
    required CryptoBridge crypto,
    required ApiClient api,
    required SessionRepository sessions,
    required Future<List<Device>> Function() myDeviceList,
    required void Function(Account) recordPeerDisplayName,
    required int? Function() contentTtlSeconds,
  })  : _host = host,
        _crypto = crypto,
        _api = api,
        _sessions = sessions,
        _myDeviceList = myDeviceList,
        _recordPeerDisplayName = recordPeerDisplayName,
        _contentTtlSeconds = contentTtlSeconds;

  final NotifierServiceHost _host;
  final CryptoBridge _crypto;
  final ApiClient _api;
  final SessionRepository _sessions;
  final Future<List<Device>> Function() _myDeviceList;
  final void Function(Account) _recordPeerDisplayName;
  final int? Function() _contentTtlSeconds;

  /// Resolves a username to a [MemberSeed] for group creation WITHOUT starting
  /// a 1:1 conversation. Throws (ApiError) if the username doesn't exist.
  Future<MemberSeed> resolveGroupMemberByUsername(String username) async {
    final acc = await _api.lookupAccount(username);
    _recordPeerDisplayName(acc);
    return MemberSeed(
      accountId: acc.accountId,
      username: acc.username,
      deviceId: acc.deviceId ?? acc.accountId,
      identityPubKey: acc.identityPubKey,
      x25519PubKey: acc.x25519PubKey,
    );
  }

  /// Bootstrap a new MLS group with [groupName], inviting [initialMembers].
  /// Returns the new groupId. Throws [ArgumentError] on invalid input,
  /// [GroupMemberUnavailableException] when a member has no KeyPackage.
  Future<String> createGroup({
    required String groupName,
    required String selfUsername,
    required List<MemberSeed> initialMembers,
  }) async {
    // 1. Validate input — no side effects until this passes.
    if (initialMembers.length < 2 || initialMembers.length > 31) {
      throw ArgumentError.value(
        initialMembers.length,
        'initialMembers.length',
        'must be in [2, 31] (final group size = self + invitees ≤ 32)',
      );
    }
    if (groupName.trim().isEmpty) {
      throw ArgumentError.value(groupName, 'groupName', 'must not be blank');
    }

    // 2. Generate group id.
    final groupId = 'group:${_newV4Uuid()}';

    // 3. Look up self's account info.
    final selfAccount = await _api.lookupAccount(selfUsername);
    final session = await _sessions.current();
    if (session == null) {
      throw StateError('createGroup requires an active session');
    }

    // 4. Pre-fetch KeyPackages for EVERY device of every invitee + our OWN other
    //    devices (self-sync), so each device becomes its own MLS leaf.
    final inviteeDevices =
        <({MemberSeed seed, String deviceId, List<int> kp})>[];
    for (final m in initialMembers) {
      List<DeviceKeyPackageResult> devs = const [];
      try {
        devs = await _api.lookupDeviceKeyPackages(m.username);
      } catch (_) {/* fall back to the single primary KeyPackage below */}
      if (devs.isEmpty) {
        try {
          final r = await _api.lookupKeyPackage(m.username);
          inviteeDevices.add((seed: m, deviceId: m.deviceId, kp: r.keyPackage));
        } catch (_) {
          throw GroupMemberUnavailableException(m.username);
        }
      } else {
        for (final d in devs) {
          inviteeDevices.add((seed: m, deviceId: d.deviceId, kp: d.keyPackage));
        }
      }
    }
    final ownDevices = <({String deviceId, List<int> kp, List<int> x25519})>[];
    final myOthers = (await _myDeviceList())
        .where((d) => d.deviceId != session.deviceId)
        .toList();
    if (myOthers.isNotEmpty) {
      try {
        final myKps = await _api.lookupDeviceKeyPackages(selfUsername);
        final kpByDev = {for (final k in myKps) k.deviceId: k.keyPackage};
        for (final d in myOthers) {
          final kp = kpByDev[d.deviceId];
          if (kp != null) {
            ownDevices
                .add((deviceId: d.deviceId, kp: kp, x25519: d.x25519PubKey));
          }
        }
      } catch (_) {/* skip self-sync devices if unavailable */}
    }

    // 5. Create the MLS group.
    await _crypto.createGroup(conversationId: groupId);

    // 6. Add every device leaf in a SINGLE commit → one epoch, one Welcome.
    final addResult = await _crypto.addMembers(
      groupId: groupId,
      peerKeyPackages: [
        for (final d in inviteeDevices) d.kp,
        for (final d in ownDevices) d.kp,
      ],
    );

    // 7. Submit the (single) Welcome to every added device. Best-effort per
    //    device: one device's failure must NOT abort the whole group.
    Future<void> welcome(String accountId, String deviceId) async {
      try {
        await _api.submitMessage(SubmitMessagePayload(
          conversationId: groupId,
          envelopeType: wire.EnvelopeType.mlsWelcome,
          recipientAccountId: accountId,
          recipientDeviceId: deviceId,
          ciphertext: addResult.welcome,
        ));
      } catch (e) {
        debugPrint('createGroup: Welcome to $deviceId failed: $e');
      }
    }

    for (final d in inviteeDevices) {
      await welcome(d.seed.accountId, d.deviceId);
    }
    for (final d in ownDevices) {
      await welcome(session.accountId, d.deviceId);
    }

    // 8. Persist locally — one member row PER DEVICE.
    final selfMember = GroupMember(
      accountId: session.accountId,
      username: selfAccount.username,
      deviceId: session.deviceId,
      identityPubKey: selfAccount.identityPubKey,
      x25519PubKey: selfAccount.x25519PubKey,
      isAdmin: true,
      isSelf: true,
    );
    final members = [
      selfMember,
      for (final d in inviteeDevices)
        GroupMember(
          accountId: d.seed.accountId,
          username: d.seed.username,
          deviceId: d.deviceId,
          identityPubKey: d.seed.identityPubKey,
          x25519PubKey: d.seed.x25519PubKey,
          isAdmin: false,
          isSelf: false,
        ),
      for (final d in ownDevices)
        GroupMember(
          accountId: session.accountId,
          username: selfAccount.username,
          deviceId: d.deviceId,
          identityPubKey: selfAccount.identityPubKey,
          x25519PubKey: d.x25519,
          isAdmin: false,
          isSelf: true,
        ),
    ];
    final epoch = await _crypto.currentEpoch(groupId);
    final convo = Conversation(
      id: groupId,
      peerUsername: '',
      peerAccountId: '',
      peerDeviceId: '',
      peerIdentityPubKey: const [],
      messages: const [],
      unreadCount: 0,
      kind: ConversationKind.group,
      groupName: groupName.trim(),
      members: members,
      mlsEpoch: epoch,
      cryptoMode: CryptoMode.mls,
    );
    await _host.db.upsertConversation(convo);
    await _host.db.upsertGroupMembers(groupId, members);
    _host.setConversation(groupId, convo);
    _host.notifyHost();

    // Ship the group name + roster so recipients (who only got the MLS Welcome,
    // which carries neither) can render the group + fan out their replies.
    await broadcastGroupInfo(groupId, members, epoch);
    return groupId;
  }

  /// Encrypt + fan out a [SystemEvent.groupInfo] (name + full roster) to every
  /// other member's device. Best-effort.
  Future<void> broadcastGroupInfo(
    String groupId,
    List<GroupMember> members,
    int epoch,
  ) async {
    final convo = _host.conversation(groupId);
    final name = convo?.groupName ?? '';
    final ev = SystemEvent.groupInfo(
      groupName: name,
      groupAvatar: convo?.groupAvatar,
      epoch: epoch,
      members: [
        for (final m in members)
          GroupInfoMember(
            accountId: m.accountId,
            username: m.username,
            deviceId: m.deviceId,
            identityPubKey: m.identityPubKey,
            x25519PubKey: m.x25519PubKey,
            isAdmin: m.isAdmin,
          ),
      ],
    );
    final ciphertext = await _crypto.encrypt(
      groupId: groupId,
      plaintext: utf8.encode(ev.toJsonString()),
    );
    // Fan out to every member device EXCEPT this one (our own other devices are
    // members too — they need the roster to render + fan out replies).
    final myDeviceId = (await _sessions.current())?.deviceId;
    for (final m in members.where((m) => m.deviceId != myDeviceId)) {
      try {
        await _api.submitMessage(SubmitMessagePayload(
          conversationId: groupId,
          envelopeType: wire.EnvelopeType.mlsApplication,
          recipientAccountId: m.accountId,
          recipientDeviceId: m.deviceId,
          ciphertext: ciphertext,
          ttlSeconds: _contentTtlSeconds(),
        ));
      } catch (e) {
        debugPrint('group-info broadcast to ${m.username} failed: $e');
      }
    }
  }

  /// Add [newMember] to the existing group [conversationId]. Spec §10.5.
  /// Throws [StateError] if the conversation isn't a group, is at capacity (32),
  /// or the member is already in the group.
  Future<void> addMemberToGroup({
    required String conversationId,
    required MemberSeed newMember,
  }) {
    return _host.runLocked(conversationId, () async {
      final convo = _host.conversation(conversationId);
      if (convo == null || convo.kind != ConversationKind.group) {
        throw StateError('not a group conversation: $conversationId');
      }
      if (convo.members.length >= 32) {
        throw StateError('group at max capacity (32)');
      }
      if (convo.members.any((m) => m.accountId == newMember.accountId)) {
        throw StateError('member already in group: ${newMember.username}');
      }
      final myDeviceId = (await _sessions.current())?.deviceId;

      // 1. Fetch the new member's device KeyPackages (all devices), falling back
      //    to the single primary KeyPackage.
      final newDevices = <({String deviceId, List<int> kp})>[];
      List<DeviceKeyPackageResult> devs = const [];
      try {
        devs = await _api.lookupDeviceKeyPackages(newMember.username);
      } catch (_) {/* fall back to single primary KeyPackage below */}
      if (devs.isEmpty) {
        final kpResult = await _api.lookupKeyPackage(newMember.username);
        newDevices.add((deviceId: newMember.deviceId, kp: kpResult.keyPackage));
      } else {
        for (final d in devs) {
          newDevices.add((deviceId: d.deviceId, kp: d.keyPackage));
        }
      }

      // 2. Add all the new member's device leaves in a single commit.
      final r = await _crypto.addMembers(
        groupId: conversationId,
        peerKeyPackages: [for (final d in newDevices) d.kp],
      );

      // 3. Welcome to each new device — best-effort per device.
      for (final d in newDevices) {
        try {
          await _api.submitMessage(SubmitMessagePayload(
            conversationId: conversationId,
            envelopeType: wire.EnvelopeType.mlsWelcome,
            recipientAccountId: newMember.accountId,
            recipientDeviceId: d.deviceId,
            ciphertext: r.welcome,
          ));
        } catch (e) {
          debugPrint('addMember: Welcome to ${d.deviceId} failed: $e');
        }
      }

      // 4. Commit to every existing member device EXCEPT this one.
      for (final existing
          in convo.members.where((m) => m.deviceId != myDeviceId)) {
        await _api.submitMessage(SubmitMessagePayload(
          conversationId: conversationId,
          envelopeType: wire.EnvelopeType.mlsHandshake,
          recipientAccountId: existing.accountId,
          recipientDeviceId: existing.deviceId,
          ciphertext: r.commit,
        ));
      }

      // 5. Update local membership projection — one row per new device.
      final newGms = [
        for (final d in newDevices)
          GroupMember(
            accountId: newMember.accountId,
            username: newMember.username,
            deviceId: d.deviceId,
            identityPubKey: newMember.identityPubKey,
            x25519PubKey: newMember.x25519PubKey,
            isAdmin: false,
            isSelf: false,
          ),
      ];
      final updatedMembers = [...convo.members, ...newGms];
      final epoch = await _crypto.currentEpoch(conversationId);
      await _host.db.upsertGroupMembers(conversationId, updatedMembers);
      await _host.db
          .updateConversationGroupFields(conversationId, mlsEpoch: epoch);

      // 6. Build + encrypt + broadcast a member_joined system event.
      final ev = SystemEvent.memberJoined(
        accountId: newMember.accountId,
        username: newMember.username,
        epoch: epoch,
      );
      final plaintext = utf8.encode(ev.toJsonString());
      final ciphertext = await _crypto.encrypt(
        groupId: conversationId,
        plaintext: plaintext,
      );
      for (final m in updatedMembers) {
        await _api.submitMessage(SubmitMessagePayload(
          conversationId: conversationId,
          envelopeType: wire.EnvelopeType.mlsApplication,
          recipientAccountId: m.accountId,
          recipientDeviceId: m.deviceId,
          ciphertext: ciphertext,
          ttlSeconds: _contentTtlSeconds(),
        ));
      }

      // 7. Build updated Conversation; update in-memory + persist.
      final updated = Conversation(
        id: convo.id,
        peerUsername: convo.peerUsername,
        peerAccountId: convo.peerAccountId,
        peerDeviceId: convo.peerDeviceId,
        peerIdentityPubKey: convo.peerIdentityPubKey,
        peerX25519PubKey: convo.peerX25519PubKey,
        messages: convo.messages,
        unreadCount: convo.unreadCount,
        verified: convo.verified,
        hasMoreOlderMessages: convo.hasMoreOlderMessages,
        cryptoMode: convo.cryptoMode,
        needsReestablishment: convo.needsReestablishment,
        kind: convo.kind,
        groupName: convo.groupName,
        groupAvatar: convo.groupAvatar,
        members: updatedMembers,
        mlsEpoch: epoch,
      );
      _host.setConversation(conversationId, updated);
      await _host.db.upsertConversation(updated);
      _host.notifyHost();

      // The new member's Welcome carries no name/roster — ship the full group
      // info. Existing members harmlessly re-apply it.
      await broadcastGroupInfo(conversationId, updatedMembers, epoch);
    });
  }

  /// Adds one of OUR OWN newly-linked devices ([newDevice]) to the existing
  /// group [conversationId] using [keyPackage] (a FRESH single-use package for
  /// that device). Welcome goes to the new device, the Commit to every other
  /// member device (not this one, not the newcomer), then the updated roster is
  /// re-broadcast so the newcomer can render the group and every member fans
  /// out to it. No-op when the conversation is not an MLS group or the device is
  /// already a member (idempotent re-runs). Throws [StateError] if this account
  /// has no member row in the group.
  Future<void> addOwnDeviceToGroup({
    required String conversationId,
    required Device newDevice,
    required List<int> keyPackage,
  }) {
    return _host.runLocked(conversationId, () async {
      final convo = _host.conversation(conversationId);
      if (convo == null ||
          convo.kind != ConversationKind.group ||
          convo.cryptoMode != CryptoMode.mls) {
        return;
      }
      if (convo.members.any((m) => m.deviceId == newDevice.deviceId)) return;
      final session = await _sessions.current();
      if (session == null) return;
      final selfRows =
          convo.members.where((m) => m.accountId == session.accountId);
      if (selfRows.isEmpty) {
        throw StateError('not a member of group: $conversationId');
      }
      final self = selfRows.first;

      final r = await _crypto.addMember(
          groupId: conversationId, peerKeyPackage: keyPackage);
      // The Welcome must reach the newcomer — let a failure propagate so the
      // sweep stays pending rather than recording the device as handled.
      await _api.submitMessage(SubmitMessagePayload(
        conversationId: conversationId,
        envelopeType: wire.EnvelopeType.mlsWelcome,
        recipientAccountId: session.accountId,
        recipientDeviceId: newDevice.deviceId,
        ciphertext: r.welcome,
      ));
      // Commit to every existing member device except this one.
      for (final m in convo.members.where((m) => m.deviceId != session.deviceId)) {
        try {
          await _api.submitMessage(SubmitMessagePayload(
            conversationId: conversationId,
            envelopeType: wire.EnvelopeType.mlsHandshake,
            recipientAccountId: m.accountId,
            recipientDeviceId: m.deviceId,
            ciphertext: r.commit,
          ));
        } catch (e) {
          debugPrint('addOwnDevice: commit to ${m.deviceId} failed: $e');
        }
      }

      final updatedMembers = [
        ...convo.members,
        GroupMember(
          accountId: session.accountId,
          username: self.username,
          deviceId: newDevice.deviceId,
          identityPubKey: self.identityPubKey,
          x25519PubKey: newDevice.x25519PubKey,
          isAdmin: false,
          isSelf: true,
        ),
      ];
      final epoch = await _crypto.currentEpoch(conversationId);
      await _host.db.upsertGroupMembers(conversationId, updatedMembers);
      await _host.db
          .updateConversationGroupFields(conversationId, mlsEpoch: epoch);
      _host.setConversation(conversationId,
          convo.copyWith(members: updatedMembers, mlsEpoch: epoch));
      _host.notifyHost();

      // The Welcome carries no name/roster; existing members harmlessly
      // re-apply it and learn the new device to fan out to.
      await broadcastGroupInfo(conversationId, updatedMembers, epoch);
    });
  }

  /// Produces a canonical UUID v4 string using [Random.secure].
  String _newV4Uuid() {
    final rng = Random.secure();
    final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
    bytes[6] = (bytes[6] & 0x0F) | 0x40; // version 4
    bytes[8] = (bytes[8] & 0x3F) | 0x80; // variant 1 (RFC 4122)
    String hex(int n, int len) => n.toRadixString(16).padLeft(len, '0');
    final hs = bytes.map((b) => hex(b, 2)).join();
    return '${hs.substring(0, 8)}-${hs.substring(8, 12)}-'
        '${hs.substring(12, 16)}-${hs.substring(16, 20)}-'
        '${hs.substring(20)}';
  }
}
