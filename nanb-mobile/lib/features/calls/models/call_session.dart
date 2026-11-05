import 'package:flutter/foundation.dart';

import 'call_signal.dart';

/// Who initiated the call.
enum CallDirection { outgoing, incoming }

/// Lifecycle of a single 1:1 call. A session exists from the moment it starts
/// ringing until it ends:
///
///   outgoingRinging ─▶ connecting ─▶ active ─▶ ended
///   incomingRinging ─▶ connecting ─▶ active ─▶ ended
///                  └────────────────────────▶ ended  (declined / missed)
enum CallStatus {
  /// We placed the call; waiting for the callee to accept.
  outgoingRinging,

  /// The callee is ringing us; waiting for the user to accept/decline.
  incomingRinging,

  /// Accepted on both sides; SDP/ICE negotiation + media connect in progress.
  connecting,

  /// Media is flowing.
  active,

  /// Terminal. [CallSession.endReason] says why.
  ended,
}

/// Immutable snapshot of the current (single) 1:1 call. The [CallController]
/// owns exactly one of these at a time and replaces it on every transition.
@immutable
class CallSession {
  const CallSession({
    required this.callId,
    required this.conversationId,
    required this.peerAccountId,
    required this.peerUsername,
    required this.peerDeviceId,
    required this.direction,
    required this.status,
    required this.mediaKind,
    required this.startedAt,
    this.micMuted = false,
    this.speakerOn = false,
    this.cameraEnabled = true,
    this.usingFrontCamera = true,
    this.endReason,
    this.connectedAt,
    this.awaitingInvite = false,
  });

  final String callId;
  final String conversationId;
  final String peerAccountId;
  final String peerUsername;

  /// The peer device this call is bound to. For an outgoing call it is empty
  /// until the callee's `accept` names the winning device (multi-device: first
  /// accept wins); for an incoming call it is the inviting device.
  final String peerDeviceId;

  final CallDirection direction;
  final CallStatus status;
  final CallMediaKind mediaKind;

  /// When the session was created (ring start). Used for the local call log.
  final DateTime startedAt;

  final bool micMuted;
  final bool speakerOn;

  /// Video calls only: whether the local camera track is currently sending.
  /// Toggled by the "turn my video off" control. Meaningless for audio calls.
  final bool cameraEnabled;

  /// Video calls only: true when capturing from the front (selfie) camera — the
  /// local preview is mirrored in that case. Flipped by the flip-camera control.
  final bool usingFrontCamera;

  /// Set once [status] is [CallStatus.ended].
  final CallEndReason? endReason;

  /// When media became [CallStatus.active]; null until then. Drives the
  /// in-call duration timer and the "X:YZ" call-log entry.
  final DateTime? connectedAt;

  /// True for a **from-push placeholder** ring: the device was woken by a call
  /// push and is ringing from the push payload (caller name only) BEFORE the
  /// real E2EE invite has been caught up + decrypted. Once the invite arrives,
  /// [CallController] reconciles it (fills in callId/peerDeviceId/peerAccountId)
  /// and clears this flag. While true, callId/peerDeviceId/peerAccountId are
  /// empty, so the call can't yet be accepted on the wire — answering is queued
  /// until reconciliation.
  final bool awaitingInvite;

  bool get isLive => status != CallStatus.ended;
  bool get isRinging =>
      status == CallStatus.outgoingRinging ||
      status == CallStatus.incomingRinging;

  CallSession copyWith({
    String? peerDeviceId,
    CallStatus? status,
    bool? micMuted,
    bool? speakerOn,
    bool? cameraEnabled,
    bool? usingFrontCamera,
    CallEndReason? endReason,
    DateTime? connectedAt,
    bool? awaitingInvite,
  }) {
    return CallSession(
      callId: callId,
      conversationId: conversationId,
      peerAccountId: peerAccountId,
      peerUsername: peerUsername,
      peerDeviceId: peerDeviceId ?? this.peerDeviceId,
      direction: direction,
      status: status ?? this.status,
      mediaKind: mediaKind,
      startedAt: startedAt,
      micMuted: micMuted ?? this.micMuted,
      speakerOn: speakerOn ?? this.speakerOn,
      cameraEnabled: cameraEnabled ?? this.cameraEnabled,
      usingFrontCamera: usingFrontCamera ?? this.usingFrontCamera,
      endReason: endReason ?? this.endReason,
      connectedAt: connectedAt ?? this.connectedAt,
      awaitingInvite: awaitingInvite ?? this.awaitingInvite,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CallSession &&
          callId == other.callId &&
          conversationId == other.conversationId &&
          peerDeviceId == other.peerDeviceId &&
          direction == other.direction &&
          status == other.status &&
          mediaKind == other.mediaKind &&
          micMuted == other.micMuted &&
          speakerOn == other.speakerOn &&
          cameraEnabled == other.cameraEnabled &&
          usingFrontCamera == other.usingFrontCamera &&
          endReason == other.endReason &&
          connectedAt == other.connectedAt &&
          awaitingInvite == other.awaitingInvite;

  @override
  int get hashCode => Object.hash(
        callId,
        conversationId,
        peerDeviceId,
        direction,
        status,
        mediaKind,
        micMuted,
        speakerOn,
        cameraEnabled,
        usingFrontCamera,
        endReason,
        connectedAt,
        awaitingInvite,
      );
}
