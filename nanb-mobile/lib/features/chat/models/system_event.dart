import 'dart:convert';

import 'package:flutter/foundation.dart';

/// A member entry inside a [SystemEventKind.groupInfo] roster broadcast.
/// MLS transmits the cryptographic group but NOT the app-level name +
/// roster — the creator/admin ships this so recipients can render the
/// group and fan out their own replies. Byte keys travel base64.
@immutable
class GroupInfoMember {
  const GroupInfoMember({
    required this.accountId,
    required this.username,
    required this.deviceId,
    required this.identityPubKey,
    required this.x25519PubKey,
    required this.isAdmin,
  });

  final String accountId;
  final String username;
  final String deviceId;
  final List<int> identityPubKey;
  final List<int> x25519PubKey;
  final bool isAdmin;

  Map<String, Object?> toMap() => {
        'a': accountId,
        'u': username,
        'd': deviceId,
        'ik': base64Encode(identityPubKey),
        'xk': base64Encode(x25519PubKey),
        if (isAdmin) 'admin': true,
      };

  static GroupInfoMember? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final a = raw['a'], u = raw['u'], d = raw['d'];
    if (a is! String || u is! String || d is! String) return null;
    try {
      return GroupInfoMember(
        accountId: a,
        username: u,
        deviceId: d,
        identityPubKey: base64Decode(raw['ik'] as String? ?? ''),
        x25519PubKey: base64Decode(raw['xk'] as String? ?? ''),
        isAdmin: raw['admin'] == true,
      );
    } catch (_) {
      return null;
    }
  }
}

/// Discriminator for in-thread system events. Wire form is the
/// snake_case string serialized in the `_system` JSON key.
enum SystemEventKind {
  memberJoined,
  memberRemoved,
  groupRenamed,
  identityKeyChanged,
  sessionReestablished,
  youWereRemoved,
  groupInfo,
  call,
  screenshotTaken;

  String get wireName {
    switch (this) {
      case SystemEventKind.memberJoined:
        return 'member_joined';
      case SystemEventKind.memberRemoved:
        return 'member_removed';
      case SystemEventKind.groupRenamed:
        return 'group_renamed';
      case SystemEventKind.identityKeyChanged:
        return 'identity_key_changed';
      case SystemEventKind.sessionReestablished:
        return 'session_reestablished';
      case SystemEventKind.youWereRemoved:
        return 'you_were_removed';
      case SystemEventKind.groupInfo:
        return 'group_info';
      case SystemEventKind.call:
        return 'call';
      case SystemEventKind.screenshotTaken:
        return 'screenshot_taken';
    }
  }

  static SystemEventKind? fromWire(String s) {
    for (final k in SystemEventKind.values) {
      if (k.wireName == s) return k;
    }
    return null;
  }
}

/// In-thread system event (spec §10.4) carried as an MLS application
/// message with a `_system`-keyed JSON body, or injected locally for
/// identity-key changes + self-removed notices.
@immutable
class SystemEvent {
  const SystemEvent({
    required this.kind,
    this.accountId,
    this.username,
    this.epoch,
    this.by,
    this.fromName,
    this.toName,
    this.at,
    this.groupName,
    this.groupAvatar,
    this.members,
    this.callOutgoing,
    this.callOutcome,
    this.callDurationSeconds,
    this.callVideo,
    this.byYou,
  });

  /// Group name + full member roster, broadcast by the creator (as the
  /// first application message after the Welcomes) and re-broadcast on
  /// membership changes so every member learns the human-readable name and
  /// has the device list needed to fan out their own sends.
  factory SystemEvent.groupInfo({
    required String groupName,
    required List<GroupInfoMember> members,
    required int epoch,
    String? groupAvatar,
  }) =>
      SystemEvent(
        kind: SystemEventKind.groupInfo,
        groupName: groupName,
        groupAvatar: groupAvatar,
        members: members,
        epoch: epoch,
      );

  factory SystemEvent.memberJoined({
    required String accountId,
    required String username,
    required int epoch,
  }) =>
      SystemEvent(
        kind: SystemEventKind.memberJoined,
        accountId: accountId,
        username: username,
        epoch: epoch,
      );

  factory SystemEvent.memberRemoved({
    required String accountId,
    required String username,
    required int epoch,
    required String by,
  }) =>
      SystemEvent(
        kind: SystemEventKind.memberRemoved,
        accountId: accountId,
        username: username,
        epoch: epoch,
        by: by,
      );

  factory SystemEvent.groupRenamed({
    required String from,
    required String to,
    required int epoch,
    required String by,
  }) =>
      SystemEvent(
        kind: SystemEventKind.groupRenamed,
        fromName: from,
        toName: to,
        epoch: epoch,
        by: by,
      );

  factory SystemEvent.identityKeyChanged({
    required String username,
    required DateTime at,
  }) =>
      SystemEvent(
        kind: SystemEventKind.identityKeyChanged,
        username: username,
        at: at.toUtc(),
      );

  /// Injected locally (never sent on the wire) after the conversation ratchet
  /// is automatically re-established — the peer wiped their device and
  /// restored from the same recovery phrase, so we re-seeded the forward-
  /// secret chains from their unchanged X25519 key and messages flow again.
  factory SystemEvent.sessionReestablished({
    required String username,
    required DateTime at,
  }) =>
      SystemEvent(
        kind: SystemEventKind.sessionReestablished,
        username: username,
        at: at.toUtc(),
      );

  factory SystemEvent.youWereRemoved({required String by}) =>
      SystemEvent(
        kind: SystemEventKind.youWereRemoved,
        by: by,
      );

  /// Someone took a screenshot of a chat kept screenshot-protected (iOS can't
  /// block a still capture, so this notice is the real protection). Shown on
  /// BOTH sides so each end sees the capture happened: pass [username] on the
  /// RECIPIENT's side (the screenshotter is the conversation peer) to name them;
  /// pass `byYou: true` on the SCREENSHOTTER's own side to read "You took a
  /// screenshot".
  factory SystemEvent.screenshotTaken({
    String? username,
    bool byYou = false,
    required DateTime at,
  }) =>
      SystemEvent(
        kind: SystemEventKind.screenshotTaken,
        username: username,
        byYou: byYou,
        at: at.toUtc(),
      );

  /// A LOCAL-ONLY 1:1 call-log entry (never sent on the wire). [outgoing] is
  /// the direction; [outcome] is one of `completed` | `missed` | `declined` |
  /// `failed` | `cancelled`; [durationSeconds] is set for a completed call.
  factory SystemEvent.call({
    required bool outgoing,
    required String outcome,
    int? durationSeconds,
    bool video = false,
    required DateTime at,
  }) =>
      SystemEvent(
        kind: SystemEventKind.call,
        callOutgoing: outgoing,
        callOutcome: outcome,
        callDurationSeconds: durationSeconds,
        callVideo: video,
        at: at.toUtc(),
      );

  final SystemEventKind kind;
  final String? accountId;
  final String? username;
  final int? epoch;
  final String? by;
  final String? fromName;
  final String? toName;
  final DateTime? at;

  /// Non-null only for [SystemEventKind.groupInfo].
  final String? groupName;

  /// Group-photo descriptor JSON, carried by [SystemEventKind.groupInfo] so
  /// members who join later learn the photo too. Null when the group has none.
  final String? groupAvatar;
  final List<GroupInfoMember>? members;

  /// Non-null only for [SystemEventKind.call].
  final bool? callOutgoing;
  final String? callOutcome;
  final int? callDurationSeconds;

  /// True for a video call (vs audio). Null/false on legacy logs → reads as
  /// audio, so the label stays "call" for pre-feature entries.
  final bool? callVideo;

  /// True only for a [SystemEventKind.screenshotTaken] inserted on the
  /// screenshotter's OWN side, so it renders "You took a screenshot" rather
  /// than a username. Null/false on the recipient's copy (which names the peer).
  final bool? byYou;

  String toJsonString() {
    final m = <String, Object?>{'_system': kind.wireName};
    if (accountId != null) m['account_id'] = accountId;
    if (username != null) m['username'] = username;
    if (epoch != null) m['epoch'] = epoch;
    if (by != null) m['by'] = by;
    if (fromName != null) m['from'] = fromName;
    if (toName != null) m['to'] = toName;
    if (at != null) m['at'] = at!.toUtc().toIso8601String();
    if (groupName != null) m['gname'] = groupName;
    if (groupAvatar != null) m['gavatar'] = groupAvatar;
    if (members != null) {
      m['members'] = [for (final mem in members!) mem.toMap()];
    }
    if (callOutgoing != null) m['c_out'] = callOutgoing;
    if (callOutcome != null) m['c_res'] = callOutcome;
    if (callDurationSeconds != null) m['c_dur'] = callDurationSeconds;
    if (callVideo == true) m['c_vid'] = true;
    if (byYou == true) m['by_you'] = true;
    return jsonEncode(m);
  }

  /// Returns null if [body] is not a parseable `_system` JSON payload.
  static SystemEvent? tryDecode(String body) {
    if (body.isEmpty || body.codeUnitAt(0) != 0x7B) return null;
    Object? raw;
    try {
      raw = jsonDecode(body);
    } catch (_) {
      return null;
    }
    if (raw is! Map<String, Object?>) return null;
    final tag = raw['_system'];
    if (tag is! String) return null;
    final kind = SystemEventKind.fromWire(tag);
    if (kind == null) return null;
    try {
      final atRaw = raw['at'];
      final membersRaw = raw['members'];
      return SystemEvent(
        kind: kind,
        accountId: raw['account_id'] as String?,
        username: raw['username'] as String?,
        epoch: raw['epoch'] as int?,
        by: raw['by'] as String?,
        fromName: raw['from'] as String?,
        toName: raw['to'] as String?,
        at: atRaw is String ? DateTime.tryParse(atRaw)?.toUtc() : null,
        groupName: raw['gname'] as String?,
        groupAvatar: raw['gavatar'] as String?,
        members: membersRaw is List
            ? membersRaw
                .map(GroupInfoMember.fromMap)
                .whereType<GroupInfoMember>()
                .toList(growable: false)
            : null,
        callOutgoing: raw['c_out'] as bool?,
        callOutcome: raw['c_res'] as String?,
        callDurationSeconds: raw['c_dur'] as int?,
        callVideo: raw['c_vid'] as bool?,
        byYou: raw['by_you'] as bool?,
      );
    } on TypeError {
      return null;
    }
  }

  /// Human-readable rendering used by `SystemLine`. Pure function — UI
  /// passes the result straight to the widget.
  String get displayText {
    switch (kind) {
      case SystemEventKind.memberJoined:
        return '${username ?? "Someone"} joined the group';
      case SystemEventKind.memberRemoved:
        return '${by ?? "Someone"} removed ${username ?? "a member"}';
      case SystemEventKind.groupRenamed:
        return '${by ?? "Someone"} renamed the group · "${fromName ?? ""}" → "${toName ?? ""}"';
      case SystemEventKind.identityKeyChanged:
        return '${username ?? "Peer"} has a new identity key — verify before continuing';
      case SystemEventKind.sessionReestablished:
        return 'Secure session re-established with ${username ?? "peer"}';
      case SystemEventKind.screenshotTaken:
        return (byYou ?? false)
            ? 'You took a screenshot'
            : '${username ?? "Someone"} took a screenshot';
      case SystemEventKind.youWereRemoved:
        return 'You were removed by ${by ?? "an admin"}';
      case SystemEventKind.groupInfo:
        // Silent metadata — applied to the conversation, not rendered as a
        // visible system line. displayText is only a fallback.
        return 'Group updated';
      case SystemEventKind.call:
        final dir = (callOutgoing ?? false) ? 'Outgoing' : 'Incoming';
        final noun = (callVideo ?? false) ? 'video call' : 'call';
        switch (callOutcome) {
          case 'completed':
            final d = callDurationSeconds;
            if (d == null) return '$dir $noun';
            final mm = (d ~/ 60).toString();
            final ss = (d % 60).toString().padLeft(2, '0');
            return '$dir $noun · $mm:$ss';
          case 'missed':
            return (callVideo ?? false) ? 'Missed video call' : 'Missed call';
          case 'declined':
            return (callVideo ?? false) ? 'Video call declined' : 'Call declined';
          case 'failed':
            return (callVideo ?? false) ? 'Video call failed' : 'Call failed';
          case 'cancelled':
            if (callOutgoing ?? false) {
              return (callVideo ?? false) ? 'Cancelled video call' : 'Cancelled call';
            }
            return (callVideo ?? false) ? 'Missed video call' : 'Missed call';
          default:
            return '$dir $noun';
        }
    }
  }
}
