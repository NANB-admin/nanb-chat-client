/// How the underlying peer connection's media transport is doing.
enum CallConnectionState { connecting, connected, failed, closed }

/// Abstraction over the WebRTC peer connection + local capture, so the call
/// state machine ([CallController]) is fully testable without a real media
/// stack or any infrastructure.
///
/// The production implementation (a later increment) wraps `flutter_webrtc`:
/// `getUserMedia(audio)`, an `RTCPeerConnection` configured **relay-only**
/// (`iceTransportPolicy: 'relay'`) against NANb's own TURN — so peers never
/// learn each other's IP and the server relays only encrypted SRTP (see
/// `docs/voice-calls-design.md`). The TURN/ICE configuration is the
/// implementation's concern and never leaks into this interface.
abstract class CallMediaEngine {
  /// Acquire the microphone (and, when [video] is true, the camera) and build
  /// the peer connection. [isCaller] decides whether the engine expects to
  /// produce the first offer ([createOffer]) or to answer a remote one
  /// ([createAnswer]). [video] adds a camera capture + a video m-line to the
  /// SDP; both peers must agree (the callee reads it off the `invite`'s
  /// [CallMediaKind]) so the offer/answer carry matching media sections.
  Future<void> start({required bool isCaller, bool video = false});

  /// Caller: create the SDP offer (returns the SDP string to send).
  Future<String> createOffer();

  /// Callee: apply the caller's [remoteOffer] and create the SDP answer.
  Future<String> createAnswer(String remoteOffer);

  /// Caller: apply the callee's [remoteAnswer].
  Future<void> acceptAnswer(String remoteAnswer);

  /// Caller: restart ICE after a connection failure — re-gather fresh relay
  /// candidates (new ICE ufrag/pwd) and produce a new offer to renegotiate.
  /// Returns the new offer SDP for the caller to re-send; the callee answers it
  /// through the normal [createAnswer] path. Recovers from a transient TURN
  /// relay allocation/connectivity failure instead of dropping the call.
  Future<String> restartIce();

  /// Apply a trickled remote ICE candidate
  /// (`{candidate, sdpMid, sdpMLineIndex}`).
  Future<void> addRemoteIce(Map<String, dynamic> candidate);

  /// Local ICE candidates discovered during gathering — the caller sends each
  /// to the peer as a [CallSignal.ice]. In relay-only mode these are TURN
  /// relay candidates only (no host/srflx → no IP leak).
  Stream<Map<String, dynamic>> get localIceCandidates;

  /// Transport state transitions; the controller maps `connected` → active and
  /// `failed`/`closed` → ended.
  Stream<CallConnectionState> get connectionState;

  /// Mute/unmute the local microphone track.
  Future<void> setMicMuted(bool muted);

  /// Route audio to the loudspeaker (true) or earpiece (false).
  Future<void> setSpeakerOn(bool on);

  /// Flip between the front and back camera (video calls only). No-op on an
  /// audio-only engine or before [start] has acquired the camera.
  Future<void> switchCamera();

  /// Enable/disable the local camera track (video calls only) — "turn my video
  /// off" mid-call without renegotiating. The track stays in the SDP; only its
  /// `enabled` flag flips, so the peer sees a frozen/last frame then black.
  /// No-op on an audio-only engine.
  Future<void> setCameraEnabled(bool enabled);

  /// Tear everything down (stop capture, close the peer connection). Idempotent.
  Future<void> close();
}
