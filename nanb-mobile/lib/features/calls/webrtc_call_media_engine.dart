import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'call_media_engine.dart';
import 'models/call_ice_config.dart';

/// Production [CallMediaEngine] backed by `flutter_webrtc`. Handles both audio
/// and video calls (the [start] `video` flag adds camera capture + a video
/// m-line). Kept free of any call-state logic — the [CallController] drives it
/// — so the state machine stays unit-testable against the interface while this
/// concrete engine is exercised on-device.
///
/// Video calls additionally expose [localVideoRenderer] / [remoteVideoRenderer]
/// for the UI to bind `RTCVideoView`s to. These are concrete-engine getters
/// (not on the [CallMediaEngine] interface) so the renderer type — and the
/// whole `flutter_webrtc` media stack — stays out of the state machine and its
/// tests; only the in-call screen, which is inherently WebRTC-coupled, reads
/// them (via [CallController.engine]).
class WebrtcCallMediaEngine implements CallMediaEngine {
  WebrtcCallMediaEngine({
    CallIceConfig config = const CallIceConfig(),
    Future<CallIceConfig> Function()? iceConfigLoader,
  })  : _config = config,
        _iceConfigLoader = iceConfigLoader;

  /// Fallback config; replaced by [_iceConfigLoader]'s result in [start] when a
  /// loader is provided (the production path fetches fresh TURN credentials).
  CallIceConfig _config;

  /// Loads ICE/TURN config at call-start (credentials are short-lived). On
  /// failure (TURN endpoint down / 503) we keep [_config] — relay-only with no
  /// servers — i.e. fail CLOSED on privacy rather than leaking IPs via host
  /// candidates: the call simply won't connect until TURN is reachable.
  final Future<CallIceConfig> Function()? _iceConfigLoader;

  RTCPeerConnection? _pc;
  MediaStream? _localStream;
  bool _closed = false;
  bool _video = false;

  /// Front/back camera state, tracked so [switchCamera] can report back and the
  /// UI can mirror the local preview only for the (selfie) front camera.
  bool _frontCamera = true;

  /// Video render targets — created only for a video call. The UI binds
  /// `RTCVideoView`s to these; null on an audio call.
  RTCVideoRenderer? _localRenderer;
  RTCVideoRenderer? _remoteRenderer;

  /// Local camera preview renderer (video calls only); null for audio.
  RTCVideoRenderer? get localVideoRenderer => _localRenderer;

  /// Remote video renderer (video calls only); null for audio. Its `srcObject`
  /// is set when the peer's video track arrives via `onTrack`.
  RTCVideoRenderer? get remoteVideoRenderer => _remoteRenderer;

  /// Whether the local preview should be mirrored (true for the front camera).
  bool get isFrontCamera => _frontCamera;

  final _ice = StreamController<Map<String, dynamic>>.broadcast();
  final _conn = StreamController<CallConnectionState>.broadcast();

  @override
  Stream<Map<String, dynamic>> get localIceCandidates => _ice.stream;

  @override
  Stream<CallConnectionState> get connectionState => _conn.stream;

  Map<String, dynamic> get _rtcConfig => {
        'iceServers': _config.iceServers,
        // Relay-only suppresses host/srflx candidates → no peer IP leak.
        if (_config.relayOnly) 'iceTransportPolicy': 'relay',
        'sdpSemantics': 'unified-plan',
        'bundlePolicy': 'max-bundle',
        // One transport for RTP+RTCP → fewer relay allocations to gather (and
        // fewer that can fail) on a relay-only call.
        'rtcpMuxPolicy': 'require',
        // Pre-gather a relay candidate before the offer so connectivity starts
        // sooner — shaves the TURN-allocation round-trip off call setup, which
        // is the window where a slow relay handshake otherwise times out.
        'iceCandidatePoolSize': 1,
      };

  @override
  Future<void> start({required bool isCaller, bool video = false}) async {
    _video = video;
    // Fetch fresh TURN credentials for this call. The loader retries a few
    // times (the fetch rides the same possibly-cold Tor path as everything
    // else); if it still fails we fall through to the no-servers guard below.
    final loader = _iceConfigLoader;
    if (loader != null) {
      try {
        _config = await loader();
      } catch (_) {/* handled by the no-servers guard below */}
    }
    // A relay-only call with NO ICE (TURN) servers can never gather a candidate,
    // so it would otherwise sit in "connecting" until a timeout. Fail FAST with a
    // clear error instead — CallController ends the call as failed and the user
    // can retry, rather than staring at an interminable "Connecting…". (A STUN /
    // relay-off smoke config keeps its servers and passes through.)
    if (_config.relayOnly && _config.iceServers.isEmpty) {
      throw StateError('call: no TURN servers available (relay-only)');
    }
    // Microphone always; camera only for a video call. Modest 640×480/24fps —
    // relay-only (and Tor) makes bandwidth precious, and a small frame is plenty
    // for a 1:1 phone call; libwebrtc/Opus+VP8 adapt down further under loss.
    _localStream = await navigator.mediaDevices.getUserMedia({
      'audio': true,
      'video': video
          ? {
              'facingMode': 'user',
              'width': {'ideal': 640},
              'height': {'ideal': 480},
              'frameRate': {'ideal': 24},
            }
          : false,
    });

    if (video) {
      final local = RTCVideoRenderer();
      await local.initialize();
      local.srcObject = _localStream;
      _localRenderer = local;
      final remote = RTCVideoRenderer();
      await remote.initialize();
      _remoteRenderer = remote;
    }

    final pc = await createPeerConnection(_rtcConfig);
    _pc = pc;

    for (final track in _localStream!.getTracks()) {
      await pc.addTrack(track, _localStream!);
    }

    // Remote media (unified-plan): bind the peer's video track to the remote
    // renderer when it arrives. Audio plays automatically and needs no renderer.
    pc.onTrack = (RTCTrackEvent event) {
      if (_closed) return;
      if (event.track.kind == 'video' && event.streams.isNotEmpty) {
        _remoteRenderer?.srcObject = event.streams.first;
      }
    };

    pc.onIceCandidate = (RTCIceCandidate c) {
      if (_closed || c.candidate == null) return;
      _ice.add({
        'candidate': c.candidate,
        'sdpMid': c.sdpMid,
        'sdpMLineIndex': c.sdpMLineIndex,
      });
    };
    pc.onConnectionState = (RTCPeerConnectionState s) {
      if (_closed) return;
      _conn.add(_mapState(s));
    };
  }

  @override
  Future<String> createOffer() async {
    final pc = _pc!;
    final offer = await pc.createOffer();
    await pc.setLocalDescription(offer);
    return offer.sdp!;
  }

  @override
  Future<String> createAnswer(String remoteOffer) async {
    final pc = _pc!;
    await pc.setRemoteDescription(RTCSessionDescription(remoteOffer, 'offer'));
    final answer = await pc.createAnswer();
    await pc.setLocalDescription(answer);
    return answer.sdp!;
  }

  @override
  Future<void> acceptAnswer(String remoteAnswer) async {
    await _pc!
        .setRemoteDescription(RTCSessionDescription(remoteAnswer, 'answer'));
  }

  @override
  Future<String> restartIce() async {
    final pc = _pc!;
    // Marks the connection for an ICE restart; the next offer carries a fresh
    // ICE ufrag/pwd, forcing both sides to re-gather relay candidates and redo
    // connectivity checks (recovers a stuck/failed relay path).
    await pc.restartIce();
    final offer = await pc.createOffer();
    await pc.setLocalDescription(offer);
    return offer.sdp!;
  }

  @override
  Future<void> addRemoteIce(Map<String, dynamic> candidate) async {
    await _pc?.addCandidate(RTCIceCandidate(
      candidate['candidate'] as String?,
      candidate['sdpMid'] as String?,
      candidate['sdpMLineIndex'] as int?,
    ));
  }

  @override
  Future<void> setMicMuted(bool muted) async {
    for (final track in _localStream?.getAudioTracks() ?? const []) {
      track.enabled = !muted;
    }
  }

  @override
  Future<void> setSpeakerOn(bool on) async {
    await Helper.setSpeakerphoneOn(on);
  }

  @override
  Future<void> switchCamera() async {
    if (!_video) return;
    final tracks = _localStream?.getVideoTracks() ?? const [];
    if (tracks.isEmpty) return;
    try {
      await Helper.switchCamera(tracks.first);
      _frontCamera = !_frontCamera;
    } catch (_) {/* best-effort — device may have one camera */}
  }

  @override
  Future<void> setCameraEnabled(bool enabled) async {
    if (!_video) return;
    for (final track in _localStream?.getVideoTracks() ?? const []) {
      track.enabled = enabled;
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    // Detach + dispose renderers before tearing the stream/pc down (a renderer
    // holding a stopped track's srcObject can crash the platform view).
    try {
      _localRenderer?.srcObject = null;
      _remoteRenderer?.srcObject = null;
      await _localRenderer?.dispose();
      await _remoteRenderer?.dispose();
    } catch (_) {/* best-effort */}
    _localRenderer = null;
    _remoteRenderer = null;
    try {
      for (final track in _localStream?.getTracks() ?? const []) {
        await track.stop();
      }
      await _localStream?.dispose();
    } catch (_) {/* best-effort */}
    try {
      await _pc?.close();
    } catch (_) {/* best-effort */}
    _pc = null;
    _localStream = null;
    if (!_ice.isClosed) await _ice.close();
    if (!_conn.isClosed) await _conn.close();
  }

  CallConnectionState _mapState(RTCPeerConnectionState s) {
    switch (s) {
      case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
        return CallConnectionState.connected;
      case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
        return CallConnectionState.failed;
      case RTCPeerConnectionState.RTCPeerConnectionStateClosed:
        return CallConnectionState.closed;
      // Disconnected is transient (ICE may recover) — don't end the call.
      case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
      case RTCPeerConnectionState.RTCPeerConnectionStateConnecting:
      case RTCPeerConnectionState.RTCPeerConnectionStateNew:
        return CallConnectionState.connecting;
    }
  }
}
