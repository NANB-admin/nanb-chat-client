import 'dart:async';

import 'package:nanb_chat/features/calls/call_media_engine.dart';

/// A [CallMediaEngine] fake that models the two WebRTC behaviours call setup
/// trips over, which the simpler fakes elide:
///  - local candidates are produced DURING `createOffer`/`createAnswer`/
///    `restartIce` (gathering starts at `setLocalDescription`), delivered
///    synchronously so they reach the controller before the SDP call returns;
///  - `addRemoteIce` before a remote description exists is REJECTED (throws),
///    as `RTCPeerConnection.addIceCandidate` does.
/// [startGate] holds [start] open to model a slow TURN fetch / mic prompt.
class ScriptedCallEngine implements CallMediaEngine {
  final _ice = StreamController<Map<String, dynamic>>.broadcast(sync: true);
  final _conn = StreamController<CallConnectionState>.broadcast();

  /// When set, [start] does not return until this completes.
  Completer<void>? startGate;

  /// Candidates "gathered" each time a local description is set.
  List<Map<String, dynamic>> gatherOnLocalDescription = const [];

  bool _started = false;
  bool _remoteDescriptionSet = false;

  int createOfferCalls = 0;
  int createAnswerCalls = 0;
  int acceptAnswerCalls = 0;
  int restartIceCalls = 0;
  final List<Map<String, dynamic>> appliedRemoteIce = [];
  final List<Map<String, dynamic>> rejectedRemoteIce = [];

  @override
  Future<void> start({required bool isCaller, bool video = false}) async {
    final gate = startGate;
    if (gate != null) await gate.future;
    _started = true;
  }

  void _requireStarted() {
    if (!_started) throw StateError('no peer connection yet');
  }

  void _gather() {
    for (final c in gatherOnLocalDescription) {
      _ice.add(c);
    }
  }

  @override
  Future<String> createOffer() async {
    _requireStarted();
    createOfferCalls++;
    _gather();
    return 'OFFER_SDP';
  }

  @override
  Future<String> createAnswer(String remoteOffer) async {
    _requireStarted();
    createAnswerCalls++;
    _remoteDescriptionSet = true;
    _gather();
    return 'ANSWER_SDP';
  }

  @override
  Future<void> acceptAnswer(String remoteAnswer) async {
    _requireStarted();
    acceptAnswerCalls++;
    _remoteDescriptionSet = true;
  }

  @override
  Future<String> restartIce() async {
    _requireStarted();
    restartIceCalls++;
    _gather();
    return 'RESTART_OFFER_SDP_$restartIceCalls';
  }

  @override
  Future<void> addRemoteIce(Map<String, dynamic> candidate) async {
    if (!_remoteDescriptionSet) {
      rejectedRemoteIce.add(candidate);
      throw StateError('remote description not set');
    }
    appliedRemoteIce.add(candidate);
  }

  @override
  Stream<Map<String, dynamic>> get localIceCandidates => _ice.stream;

  @override
  Stream<CallConnectionState> get connectionState => _conn.stream;

  @override
  Future<void> setMicMuted(bool muted) async {}

  @override
  Future<void> setSpeakerOn(bool on) async {}

  @override
  Future<void> switchCamera() async {}

  @override
  Future<void> setCameraEnabled(bool enabled) async {}

  @override
  Future<void> close() async {
    if (!_ice.isClosed) await _ice.close();
    if (!_conn.isClosed) await _conn.close();
  }

  void emitIce(Map<String, dynamic> c) => _ice.add(c);

  void emitConn(CallConnectionState s) => _conn.add(s);
}
