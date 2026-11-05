import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/features/calls/call_controller.dart';
import 'package:nanb_chat/features/calls/call_media_engine.dart';
import 'package:nanb_chat/features/calls/call_transport.dart';
import 'package:nanb_chat/features/calls/models/call_session.dart';
import 'package:nanb_chat/features/calls/models/call_signal.dart';

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

class _FakeEngine implements CallMediaEngine {
  final _ice = StreamController<Map<String, dynamic>>.broadcast();
  final _conn = StreamController<CallConnectionState>.broadcast();

  bool? startedAsCaller;
  bool? startedVideo;
  bool closed = false;
  bool throwOnStart = false;
  int createOfferCalls = 0;
  int restartIceCalls = 0;
  String? createdAnswerFor;
  String? acceptedAnswer;
  bool? micMuted;
  int switchCameraCalls = 0;
  bool? cameraEnabled;
  final List<Map<String, dynamic>> remoteIce = [];

  @override
  Future<void> start({required bool isCaller, bool video = false}) async {
    if (throwOnStart) throw StateError('media denied');
    startedAsCaller = isCaller;
    startedVideo = video;
  }
  @override
  Future<String> createOffer() async {
    createOfferCalls++;
    return 'OFFER_SDP';
  }

  @override
  Future<String> createAnswer(String remoteOffer) async {
    createdAnswerFor = remoteOffer;
    return 'ANSWER_SDP';
  }

  @override
  Future<void> acceptAnswer(String remoteAnswer) async =>
      acceptedAnswer = remoteAnswer;
  @override
  Future<String> restartIce() async {
    restartIceCalls++;
    return 'RESTART_OFFER_SDP';
  }
  @override
  Future<void> addRemoteIce(Map<String, dynamic> candidate) async =>
      remoteIce.add(candidate);
  @override
  Stream<Map<String, dynamic>> get localIceCandidates => _ice.stream;
  @override
  Stream<CallConnectionState> get connectionState => _conn.stream;
  @override
  Future<void> setMicMuted(bool muted) async => micMuted = muted;
  @override
  Future<void> setSpeakerOn(bool on) async {}
  @override
  Future<void> switchCamera() async => switchCameraCalls++;
  @override
  Future<void> setCameraEnabled(bool enabled) async => cameraEnabled = enabled;
  @override
  Future<void> close() async {
    closed = true;
    if (!_ice.isClosed) await _ice.close();
    if (!_conn.isClosed) await _conn.close();
  }

  void emitIce(Map<String, dynamic> c) => _ice.add(c);
  void emitConn(CallConnectionState s) => _conn.add(s);
}

class _Sent {
  _Sent(this.method, this.toAccount, this.toDevice, this.signal);
  final String method; // invite | device | all
  final String toAccount;
  final String? toDevice;
  final CallSignal signal;
}

class _RecordingTransport implements CallTransport {
  final List<_Sent> sent = [];

  /// Models the real transport's failure mode: a signal rides the E2EE
  /// store-and-forward path, so it can throw (offline, Tor mid-bootstrap, retry
  /// budget spent) rather than merely being slow.
  bool throwOnSend = false;

  /// Models the real transport's SLOW mode: a submit that queues on the
  /// conversation's FIFO lock behind other sends and only resolves when this
  /// completer does. Nothing in the state machine may block on it.
  Completer<void>? stall;

  Future<void> _record(_Sent s) async {
    sent.add(s);
    if (throwOnSend) throw StateError('transport down');
    final gate = stall;
    if (gate != null) await gate.future;
  }

  @override
  Future<void> sendInvite({
    required String toAccountId,
    required CallSignal signal,
  }) =>
      _record(_Sent('invite', toAccountId, null, signal));

  @override
  Future<void> sendToDevice({
    required String toAccountId,
    required String toDeviceId,
    required CallSignal signal,
  }) =>
      _record(_Sent('device', toAccountId, toDeviceId, signal));

  @override
  Future<void> sendToAllDevices({
    required String toAccountId,
    required CallSignal signal,
  }) =>
      _record(_Sent('all', toAccountId, null, signal));

  @override
  Future<void> sendToOwnDevices({
    required String peerAccountId,
    required CallSignal signal,
  }) =>
      _record(_Sent('own', peerAccountId, null, signal));

  Iterable<_Sent> ofType(CallSignalType t) =>
      sent.where((s) => s.signal.type == t);
  bool has(CallSignalType t) => sent.any((s) => s.signal.type == t);
}

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

const _convoId = '1to1:me-acc:peer-acc';
const _peerAcc = 'peer-acc';

void main() {
  late _FakeEngine engine;
  late _RecordingTransport transport;
  late CallController controller;
  late bool allowCall;

  setUp(() {
    engine = _FakeEngine();
    transport = _RecordingTransport();
    allowCall = true;
    controller = CallController(
      engineFactory: () => engine,
      transport: transport,
      canCall: (_) => allowCall,
      selfDeviceId: () => 'my-dev',
      generateCallId: () => 'call-1',
      clock: () => DateTime.utc(2026, 6, 14, 12),
    );
  });

  tearDown(() => controller.dispose());

  CallSignal invite() => CallSignal.invite(
        callId: 'call-1',
        mediaKind: CallMediaKind.audio,
        fromDeviceId: 'peer-dev-1',
      );

  group('outgoing call', () {
    test('placeCall rings and sends an invite to the peer account', () async {
      await controller.placeCall(
        conversationId: _convoId,
        peerAccountId: _peerAcc,
        peerUsername: '@peer',
      );

      final s = controller.current!;
      expect(s.direction, CallDirection.outgoing);
      expect(s.status, CallStatus.outgoingRinging);
      expect(engine.startedAsCaller, isTrue);
      final inv = transport.ofType(CallSignalType.invite).single;
      expect(inv.method, 'invite');
      expect(inv.toAccount, _peerAcc);
    });

    test('an unanswered outgoing call auto-cancels after the ring timeout',
        () async {
      final c = CallController(
        engineFactory: () => engine,
        transport: transport,
        canCall: (_) => true,
        selfDeviceId: () => 'my-dev',
        generateCallId: () => 'call-1',
        clock: () => DateTime.utc(2026, 6, 14, 12),
        outgoingRingTimeout: const Duration(milliseconds: 20),
      );
      await c.placeCall(
        conversationId: _convoId,
        peerAccountId: _peerAcc,
        peerUsername: '@peer',
      );
      expect(c.current!.status, CallStatus.outgoingRinging);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(c.current!.status, CallStatus.ended);
      // The callee's ring is cancelled (cancel broadcast to all of its devices).
      expect(transport.ofType(CallSignalType.cancel), isNotEmpty);
      c.dispose();
    });

    test('accept → offer/answer → connected drives the call to active', () async {
      await controller.placeCall(
        conversationId: _convoId,
        peerAccountId: _peerAcc,
        peerUsername: '@peer',
      );

      await controller.handleSignal(
        CallSignal.accept(callId: 'call-1', fromDeviceId: 'peer-dev-1'),
        fromAccountId: _peerAcc,
        fromDeviceId: 'peer-dev-1',
      );
      expect(controller.current!.status, CallStatus.connecting);
      expect(controller.current!.peerDeviceId, 'peer-dev-1');
      expect(engine.createOfferCalls, 1);
      final offer = transport.ofType(CallSignalType.offer).single;
      expect(offer.toDevice, 'peer-dev-1');
      expect(offer.signal.sdp, 'OFFER_SDP');
      // The ring is cancelled on the peer's other devices — but the cancel
      // names the WINNING device ('peer-dev-1', the one that accepted) so that
      // device ignores it rather than tearing itself down (the transport fans
      // this cancel out to every peer device, the accepter included).
      final ringCancel =
          transport.ofType(CallSignalType.cancel).firstWhere((s) => s.method == 'all');
      expect(ringCancel.signal.fromDeviceId, 'peer-dev-1');

      await controller.handleSignal(
        CallSignal.answer(callId: 'call-1', sdp: 'ANSWER_SDP'),
        fromAccountId: _peerAcc,
        fromDeviceId: 'peer-dev-1',
      );
      expect(engine.acceptedAnswer, 'ANSWER_SDP');

      engine.emitConn(CallConnectionState.connected);
      await pumpEventQueue();
      expect(controller.current!.status, CallStatus.active);
      expect(controller.current!.connectedAt, isNotNull);
    });

    test('caller recovers an ICE failure with a restart instead of dropping',
        () async {
      await controller.placeCall(
        conversationId: _convoId,
        peerAccountId: _peerAcc,
        peerUsername: '@peer',
      );
      await controller.handleSignal(
        CallSignal.accept(callId: 'call-1', fromDeviceId: 'peer-dev-1'),
        fromAccountId: _peerAcc,
        fromDeviceId: 'peer-dev-1',
      );
      await controller.handleSignal(
        CallSignal.answer(callId: 'call-1', sdp: 'ANSWER_SDP'),
        fromAccountId: _peerAcc,
        fromDeviceId: 'peer-dev-1',
      );
      engine.emitConn(CallConnectionState.connected);
      await pumpEventQueue();

      final offersBefore = transport.ofType(CallSignalType.offer).length;
      engine.emitConn(CallConnectionState.failed);
      await pumpEventQueue();

      // Recovered via ICE restart: a fresh offer re-sent, call NOT ended.
      expect(engine.restartIceCalls, 1);
      expect(transport.ofType(CallSignalType.offer).length, offersBefore + 1);
      expect(controller.current!.status, isNot(CallStatus.ended));
    });

    test('caller ends the call after exhausting ICE-restart retries', () async {
      await controller.placeCall(
        conversationId: _convoId,
        peerAccountId: _peerAcc,
        peerUsername: '@peer',
      );
      await controller.handleSignal(
        CallSignal.accept(callId: 'call-1', fromDeviceId: 'peer-dev-1'),
        fromAccountId: _peerAcc,
        fromDeviceId: 'peer-dev-1',
      );
      // 2 restarts, then give up on the 3rd consecutive failure.
      for (var i = 0; i < 3; i++) {
        engine.emitConn(CallConnectionState.failed);
        await pumpEventQueue();
      }
      expect(engine.restartIceCalls, 2);
      expect(controller.current!.status, CallStatus.ended);
      expect(controller.current!.endReason, CallEndReason.failed);
    });

    test('an accepted outgoing call that never connects ends as failed after '
        'the connect timeout (no eternal "connecting")', () async {
      final e = _FakeEngine();
      final c = CallController(
        engineFactory: () => e,
        transport: transport,
        canCall: (_) => true,
        selfDeviceId: () => 'my-dev',
        generateCallId: () => 'call-1',
        clock: () => DateTime.utc(2026, 6, 14, 12),
        connectTimeout: const Duration(milliseconds: 30),
      );
      await c.placeCall(
        conversationId: _convoId,
        peerAccountId: _peerAcc,
        peerUsername: '@peer',
      );
      await c.handleSignal(
        CallSignal.accept(callId: 'call-1', fromDeviceId: 'peer-dev-1'),
        fromAccountId: _peerAcc,
        fromDeviceId: 'peer-dev-1',
      );
      expect(c.current!.status, CallStatus.connecting);
      // Media never establishes (no `connected` emitted) — must not hang.
      await Future<void>.delayed(const Duration(milliseconds: 70));
      expect(c.current!.status, CallStatus.ended);
      expect(c.current!.endReason, CallEndReason.failed);
      c.dispose();
    });

    test('local ICE before a device is pinned is buffered, then flushed on accept',
        () async {
      await controller.placeCall(
        conversationId: _convoId,
        peerAccountId: _peerAcc,
        peerUsername: '@peer',
      );
      engine.emitIce({'candidate': 'cand-1'});
      await pumpEventQueue();
      // No ICE sent yet — we don't know which device to send to.
      expect(transport.has(CallSignalType.ice), isFalse);

      await controller.handleSignal(
        CallSignal.accept(callId: 'call-1', fromDeviceId: 'peer-dev-1'),
        fromAccountId: _peerAcc,
        fromDeviceId: 'peer-dev-1',
      );
      await pumpEventQueue();
      final ice = transport.ofType(CallSignalType.ice).single;
      expect(ice.toDevice, 'peer-dev-1');
      expect(ice.signal.candidate, {'candidate': 'cand-1'});
    });

    test('a second device accepting is cancelled (first accept wins)', () async {
      await controller.placeCall(
        conversationId: _convoId,
        peerAccountId: _peerAcc,
        peerUsername: '@peer',
      );
      await controller.handleSignal(
        CallSignal.accept(callId: 'call-1', fromDeviceId: 'peer-dev-1'),
        fromAccountId: _peerAcc,
        fromDeviceId: 'peer-dev-1',
      );
      transport.sent.clear();

      await controller.handleSignal(
        CallSignal.accept(callId: 'call-1', fromDeviceId: 'peer-dev-2'),
        fromAccountId: _peerAcc,
        fromDeviceId: 'peer-dev-2',
      );
      // dev-2 gets a cancel; the pinned device is unchanged.
      final cancel = transport.ofType(CallSignalType.cancel).single;
      expect(cancel.toDevice, 'peer-dev-2');
      expect(controller.current!.peerDeviceId, 'peer-dev-1');
    });

    test('peer decline ends the outgoing call', () async {
      await controller.placeCall(
        conversationId: _convoId,
        peerAccountId: _peerAcc,
        peerUsername: '@peer',
      );
      await controller.handleSignal(
        CallSignal.decline('call-1'),
        fromAccountId: _peerAcc,
        fromDeviceId: 'peer-dev-1',
      );
      expect(controller.current!.status, CallStatus.ended);
      expect(controller.current!.endReason, CallEndReason.declined);
      expect(engine.closed, isTrue);
    });
  });

  group('incoming call', () {
    test('invite rings and ack; accept negotiates the answer', () async {
      await controller.handleSignal(
        invite(),
        fromAccountId: _peerAcc,
        fromDeviceId: 'peer-dev-1',
        conversationId: _convoId,
        peerUsername: '@peer',
      );
      final s = controller.current!;
      expect(s.direction, CallDirection.incoming);
      expect(s.status, CallStatus.incomingRinging);
      expect(s.peerDeviceId, 'peer-dev-1');
      expect(transport.has(CallSignalType.ringing), isTrue);

      await controller.accept();
      expect(controller.current!.status, CallStatus.connecting);
      expect(engine.startedAsCaller, isFalse);
      expect(transport.has(CallSignalType.accept), isTrue);

      await controller.handleSignal(
        CallSignal.offer(callId: 'call-1', sdp: 'OFFER_SDP'),
        fromAccountId: _peerAcc,
        fromDeviceId: 'peer-dev-1',
      );
      expect(engine.createdAnswerFor, 'OFFER_SDP');
      final ans = transport.ofType(CallSignalType.answer).single;
      expect(ans.signal.sdp, 'ANSWER_SDP');

      engine.emitConn(CallConnectionState.connected);
      await pumpEventQueue();
      expect(controller.current!.status, CallStatus.active);
    });

    test('answering stops the ring on our own other devices, naming us as the winner',
        () async {
      await controller.handleSignal(invite(),
          fromAccountId: _peerAcc,
          fromDeviceId: 'peer-dev-1',
          conversationId: _convoId,
          peerUsername: '@peer');

      await controller.accept();
      await pumpEventQueue();

      final cancel = transport.ofType(CallSignalType.cancel).single.signal;
      expect(cancel.callId, 'call-1');
      expect(cancel.fromDeviceId, 'my-dev');
    });

    test('the stop-ring for answering goes to our own devices, not the peer',
        () async {
      await controller.handleSignal(invite(),
          fromAccountId: _peerAcc,
          fromDeviceId: 'peer-dev-1',
          conversationId: _convoId,
          peerUsername: '@peer');

      await controller.accept();
      await pumpEventQueue();

      expect(transport.ofType(CallSignalType.cancel).single.method, 'own');
    });

    test('declining also stops the ring on our own other devices', () async {
      await controller.handleSignal(invite(),
          fromAccountId: _peerAcc,
          fromDeviceId: 'peer-dev-1',
          conversationId: _convoId,
          peerUsername: '@peer');

      await controller.decline();
      await pumpEventQueue();

      expect(transport.ofType(CallSignalType.cancel).single.method, 'own');
    });

    test('a sibling stop-ring tears down our ringing call', () async {
      await controller.handleSignal(invite(),
          fromAccountId: _peerAcc,
          fromDeviceId: 'peer-dev-1',
          conversationId: _convoId,
          peerUsername: '@peer');

      await controller.handleSignal(
        CallSignal.cancel('call-1', exceptDeviceId: 'sibling-dev'),
        fromAccountId: '',
        fromDeviceId: 'sibling-dev',
        conversationId: _convoId,
      );

      expect(controller.current!.status, CallStatus.ended);
    });

    test('a stop-ring that beats the invite keeps the late invite from ringing',
        () async {
      await controller.handleSignal(
        CallSignal.cancel('call-1', exceptDeviceId: 'sibling-dev'),
        fromAccountId: '',
        fromDeviceId: 'sibling-dev',
        conversationId: _convoId,
      );

      await controller.handleSignal(invite(),
          fromAccountId: _peerAcc,
          fromDeviceId: 'peer-dev-1',
          conversationId: _convoId,
          peerUsername: '@peer');

      expect(controller.current, isNull);
    });

    test('callee ends an active call when the peer vanishes (recovery window '
        'elapses with no reconnect) — not stuck "in a call"', () async {
      final e = _FakeEngine();
      final c = CallController(
        engineFactory: () => e,
        transport: transport,
        canCall: (_) => true,
        selfDeviceId: () => 'my-dev',
        generateCallId: () => 'call-1',
        clock: () => DateTime.utc(2026, 6, 14, 12),
        iceRecoveryWindow: const Duration(milliseconds: 40),
      );
      await c.handleSignal(invite(),
          fromAccountId: _peerAcc,
          fromDeviceId: 'peer-dev-1',
          conversationId: _convoId,
          peerUsername: '@peer');
      await c.accept();
      await c.handleSignal(
        CallSignal.offer(callId: 'call-1', sdp: 'OFFER_SDP'),
        fromAccountId: _peerAcc,
        fromDeviceId: 'peer-dev-1',
      );
      e.emitConn(CallConnectionState.connected);
      await pumpEventQueue();
      expect(c.current!.status, CallStatus.active);

      // Peer vanishes mid-call (e.g. app killed): connection fails, no re-offer.
      e.emitConn(CallConnectionState.failed);
      await Future<void>.delayed(const Duration(milliseconds: 70));
      // The recovery window elapsed with no reconnect → the call ENDS instead
      // of hanging forever in "active".
      expect(c.current!.status, CallStatus.ended);
      expect(c.current!.endReason, CallEndReason.failed);
      expect(e.restartIceCalls, 0); // the callee never restarts (caller drives)
      c.dispose();
    });

    test('callee keeps an active call that reconnects within the window',
        () async {
      final e = _FakeEngine();
      final c = CallController(
        engineFactory: () => e,
        transport: transport,
        canCall: (_) => true,
        selfDeviceId: () => 'my-dev',
        generateCallId: () => 'call-1',
        clock: () => DateTime.utc(2026, 6, 14, 12),
        iceRecoveryWindow: const Duration(milliseconds: 40),
      );
      await c.handleSignal(invite(),
          fromAccountId: _peerAcc,
          fromDeviceId: 'peer-dev-1',
          conversationId: _convoId,
          peerUsername: '@peer');
      await c.accept();
      await c.handleSignal(
        CallSignal.offer(callId: 'call-1', sdp: 'OFFER_SDP'),
        fromAccountId: _peerAcc,
        fromDeviceId: 'peer-dev-1',
      );
      e.emitConn(CallConnectionState.connected);
      await pumpEventQueue();

      // Drops then recovers (caller's ICE restart reconnected) within the window.
      e.emitConn(CallConnectionState.failed);
      e.emitConn(CallConnectionState.connected);
      await Future<void>.delayed(const Duration(milliseconds: 70));
      expect(c.current!.status, CallStatus.active); // not ended
      c.dispose();
    });

    test('callee ends an active call whose media silently drops (disconnected → '
        'connecting) and never escalates to failed — no longer stuck "in a call"',
        () async {
      final e = _FakeEngine();
      final c = CallController(
        engineFactory: () => e,
        transport: transport,
        canCall: (_) => true,
        selfDeviceId: () => 'my-dev',
        generateCallId: () => 'call-1',
        clock: () => DateTime.utc(2026, 6, 14, 12),
        mediaDropWindow: const Duration(milliseconds: 20),
        iceRecoveryWindow: const Duration(milliseconds: 20),
      );
      await c.handleSignal(invite(),
          fromAccountId: _peerAcc,
          fromDeviceId: 'peer-dev-1',
          conversationId: _convoId,
          peerUsername: '@peer');
      await c.accept();
      await c.handleSignal(
        CallSignal.offer(callId: 'call-1', sdp: 'OFFER_SDP'),
        fromAccountId: _peerAcc,
        fromDeviceId: 'peer-dev-1',
      );
      e.emitConn(CallConnectionState.connected);
      await pumpEventQueue();
      expect(c.current!.status, CallStatus.active);

      // Peer's app is killed: WebRTC reports `disconnected` (mapped to
      // `connecting`) and NEVER escalates to `failed`. Pre-fix this sat in
      // "active" forever; now the watchdog escalates the drop and the call ends.
      e.emitConn(CallConnectionState.connecting);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(c.current!.status, CallStatus.ended);
      expect(c.current!.endReason, CallEndReason.failed);
      c.dispose();
    });

    test('a transient media drop that returns to connected keeps the call active',
        () async {
      final e = _FakeEngine();
      final c = CallController(
        engineFactory: () => e,
        transport: transport,
        canCall: (_) => true,
        selfDeviceId: () => 'my-dev',
        generateCallId: () => 'call-1',
        clock: () => DateTime.utc(2026, 6, 14, 12),
        mediaDropWindow: const Duration(milliseconds: 40),
      );
      await c.handleSignal(invite(),
          fromAccountId: _peerAcc,
          fromDeviceId: 'peer-dev-1',
          conversationId: _convoId,
          peerUsername: '@peer');
      await c.accept();
      await c.handleSignal(
        CallSignal.offer(callId: 'call-1', sdp: 'OFFER_SDP'),
        fromAccountId: _peerAcc,
        fromDeviceId: 'peer-dev-1',
      );
      e.emitConn(CallConnectionState.connected);
      await pumpEventQueue();

      // Drops to disconnected (connecting) then recovers BEFORE the window —
      // the watchdog is cancelled and the call survives the blip.
      e.emitConn(CallConnectionState.connecting);
      await Future<void>.delayed(const Duration(milliseconds: 15));
      e.emitConn(CallConnectionState.connected);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(c.current!.status, CallStatus.active);
      c.dispose();
    });

    test('the media-drop watchdog ignores a call still in INITIAL connecting '
        '(only an active call that dropped is watched)', () async {
      final e = _FakeEngine();
      final c = CallController(
        engineFactory: () => e,
        transport: transport,
        canCall: (_) => true,
        selfDeviceId: () => 'my-dev',
        generateCallId: () => 'call-1',
        clock: () => DateTime.utc(2026, 6, 14, 12),
        mediaDropWindow: const Duration(milliseconds: 20),
      );
      await c.handleSignal(invite(),
          fromAccountId: _peerAcc,
          fromDeviceId: 'peer-dev-1',
          conversationId: _convoId,
          peerUsername: '@peer');
      await c.accept(); // status: connecting, has never been active
      e.emitConn(CallConnectionState.connecting);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      // Still connecting — the media-drop watchdog must not kill a call that is
      // merely slow to connect for the first time (that's the ring timeout's job).
      expect(c.current!.status, CallStatus.connecting);
      c.dispose();
    });

    test('an accepted incoming call that never connects ends as failed after '
        'the connect timeout', () async {
      final e = _FakeEngine();
      final c = CallController(
        engineFactory: () => e,
        transport: transport,
        canCall: (_) => true,
        selfDeviceId: () => 'my-dev',
        generateCallId: () => 'call-1',
        clock: () => DateTime.utc(2026, 6, 14, 12),
        connectTimeout: const Duration(milliseconds: 30),
      );
      await c.handleSignal(invite(),
          fromAccountId: _peerAcc,
          fromDeviceId: 'peer-dev-1',
          conversationId: _convoId,
          peerUsername: '@peer');
      await c.accept();
      expect(c.current!.status, CallStatus.connecting);
      await Future<void>.delayed(const Duration(milliseconds: 70));
      expect(c.current!.status, CallStatus.ended);
      expect(c.current!.endReason, CallEndReason.failed);
      c.dispose();
    });

    test('reaching connected within the connect timeout stays active (the '
        'connect deadline is cancelled on connect)', () async {
      final e = _FakeEngine();
      final c = CallController(
        engineFactory: () => e,
        transport: transport,
        canCall: (_) => true,
        selfDeviceId: () => 'my-dev',
        generateCallId: () => 'call-1',
        clock: () => DateTime.utc(2026, 6, 14, 12),
        connectTimeout: const Duration(milliseconds: 40),
      );
      await c.handleSignal(invite(),
          fromAccountId: _peerAcc,
          fromDeviceId: 'peer-dev-1',
          conversationId: _convoId,
          peerUsername: '@peer');
      await c.accept();
      await c.handleSignal(
        CallSignal.offer(callId: 'call-1', sdp: 'OFFER_SDP'),
        fromAccountId: _peerAcc,
        fromDeviceId: 'peer-dev-1',
      );
      e.emitConn(CallConnectionState.connected);
      await pumpEventQueue();
      expect(c.current!.status, CallStatus.active);
      // Wait past the connect timeout — it must NOT fire (cancelled on connect).
      await Future<void>.delayed(const Duration(milliseconds: 70));
      expect(c.current!.status, CallStatus.active);
      c.dispose();
    });

    test('user declines an incoming call', () async {
      await controller.handleSignal(
        invite(),
        fromAccountId: _peerAcc,
        fromDeviceId: 'peer-dev-1',
        conversationId: _convoId,
        peerUsername: '@peer',
      );
      await controller.decline();
      expect(transport.has(CallSignalType.decline), isTrue);
      expect(controller.current!.status, CallStatus.ended);
      expect(controller.current!.endReason, CallEndReason.declined);
    });

    test('caller cancel while ringing ends as a missed call', () async {
      await controller.handleSignal(
        invite(),
        fromAccountId: _peerAcc,
        fromDeviceId: 'peer-dev-1',
        conversationId: _convoId,
        peerUsername: '@peer',
      );
      await controller.handleSignal(
        CallSignal.cancel('call-1'),
        fromAccountId: _peerAcc,
        fromDeviceId: 'peer-dev-1',
      );
      expect(controller.current!.status, CallStatus.ended);
      expect(controller.current!.endReason, CallEndReason.missed);
    });
  });

  group('permission rule (condition 4)', () {
    test('invite from a non-accepted/blocked 1:1 is dropped silently', () async {
      allowCall = false;
      await controller.handleSignal(
        invite(),
        fromAccountId: _peerAcc,
        fromDeviceId: 'peer-dev-1',
        conversationId: _convoId,
        peerUsername: '@peer',
      );
      expect(controller.current, isNull);
      expect(transport.has(CallSignalType.ringing), isFalse);
    });

    test('placeCall on a non-callable conversation is a no-op', () async {
      allowCall = false;
      await controller.placeCall(
        conversationId: _convoId,
        peerAccountId: _peerAcc,
        peerUsername: '@peer',
      );
      expect(controller.current, isNull);
      expect(transport.sent, isEmpty);
    });
  });

  group('busy', () {
    test('an invite while already in a call is auto-declined as busy', () async {
      await controller.placeCall(
        conversationId: _convoId,
        peerAccountId: _peerAcc,
        peerUsername: '@peer',
      );
      transport.sent.clear();

      await controller.handleSignal(
        CallSignal.invite(
          callId: 'call-2',
          mediaKind: CallMediaKind.audio,
          fromDeviceId: 'other-dev',
        ),
        fromAccountId: 'other-acc',
        fromDeviceId: 'other-dev',
        conversationId: '1to1:me-acc:other-acc',
        peerUsername: '@other',
      );

      final decline = transport.ofType(CallSignalType.decline).single;
      expect(decline.signal.reason, CallEndReason.busy);
      expect(decline.toDevice, 'other-dev');
      // Our existing call is untouched.
      expect(controller.current!.callId, 'call-1');
    });
  });

  group('hangup + controls', () {
    test('hangup tells the peer and ends the call', () async {
      await controller.placeCall(
        conversationId: _convoId,
        peerAccountId: _peerAcc,
        peerUsername: '@peer',
      );
      await controller.handleSignal(
        CallSignal.accept(callId: 'call-1', fromDeviceId: 'peer-dev-1'),
        fromAccountId: _peerAcc,
        fromDeviceId: 'peer-dev-1',
      );
      await controller.hangup();
      expect(transport.has(CallSignalType.hangup), isTrue);
      expect(controller.current!.status, CallStatus.ended);
      expect(engine.closed, isTrue);

      controller.dismiss();
      expect(controller.current, isNull);
    });

    test('mute toggles the engine and the session flag', () async {
      await controller.placeCall(
        conversationId: _convoId,
        peerAccountId: _peerAcc,
        peerUsername: '@peer',
      );
      await controller.setMicMuted(true);
      expect(engine.micMuted, isTrue);
      expect(controller.current!.micMuted, isTrue);
    });
  });

  group('call teardown + ring window', () {
    // ── Teardown must be LOCAL-FIRST ───────────────────────────────────────
    //
    // REGRESSION GUARD for "I press End and it keeps ringing until I kill the
    // app". Signalling rides the E2EE store-and-forward path: it queues on the
    // conversation's FIFO lock behind every in-flight ICE send and retries a
    // transient failure for ~19s. hangup()/decline() used to await it BEFORE
    // tearing down, so ending did nothing visible for tens of seconds — and a
    // send that THREW skipped the teardown entirely, leaving the call live (and
    // the ring tone, which stops on the ended status edge, playing) forever.
    group('teardown never waits on the network', () {
      test('hangup ends the call immediately even while the transport stalls',
          () async {
        await controller.placeCall(
          conversationId: _convoId,
          peerAccountId: _peerAcc,
          peerUsername: '@peer',
        );
        await controller.handleSignal(
          CallSignal.accept(callId: 'call-1', fromDeviceId: 'peer-dev-1'),
          fromAccountId: _peerAcc,
          fromDeviceId: 'peer-dev-1',
        );
        // From here on every send hangs, exactly like a submit stuck behind a
        // cold Tor circuit.
        transport.stall = Completer<void>();

        await controller.hangup();

        expect(controller.current!.status, CallStatus.ended);
        expect(controller.current!.endReason, CallEndReason.hangup);
        expect(engine.closed, isTrue);
        transport.stall!.complete();
      });

      test('hangup ends the call even when the teardown signal throws',
          () async {
        await controller.placeCall(
          conversationId: _convoId,
          peerAccountId: _peerAcc,
          peerUsername: '@peer',
        );
        await controller.handleSignal(
          CallSignal.accept(callId: 'call-1', fromDeviceId: 'peer-dev-1'),
          fromAccountId: _peerAcc,
          fromDeviceId: 'peer-dev-1',
        );
        transport.throwOnSend = true;

        await controller.hangup();

        expect(controller.current!.status, CallStatus.ended);
        expect(controller.current!.endReason, CallEndReason.hangup);
      });

      test('decline stops the ring even when the decline signal throws',
          () async {
        await controller.handleSignal(
          invite(),
          fromAccountId: _peerAcc,
          fromDeviceId: 'peer-dev-1',
          conversationId: _convoId,
          peerUsername: '@peer',
        );
        expect(controller.current!.status, CallStatus.incomingRinging);
        transport.throwOnSend = true;

        await controller.decline();

        expect(controller.current!.status, CallStatus.ended);
        expect(controller.current!.endReason, CallEndReason.declined);
      });

      test('the peer is still told, just not on the critical path', () async {
        await controller.handleSignal(
          invite(),
          fromAccountId: _peerAcc,
          fromDeviceId: 'peer-dev-1',
          conversationId: _convoId,
          peerUsername: '@peer',
        );
        await controller.decline();
        expect(transport.has(CallSignalType.decline), isTrue);
      });
    });

    // The no-answer window must be REAL ring time. Armed before the setup
    // above, media acquisition plus the invite's own submit (a Tor round trip,
    // retried for up to ~19s) ate a large, variable slice of it — so the caller
    // gave up on a callee whose phone had barely begun ringing.
    test('the no-answer window starts only once the invite is on the wire',
        () async {
      final gate = Completer<void>();
      transport.stall = gate;
      final c = CallController(
        engineFactory: () => engine,
        transport: transport,
        canCall: (_) => true,
        selfDeviceId: () => 'my-dev',
        generateCallId: () => 'call-1',
        clock: () => DateTime.utc(2026, 6, 14, 12),
        outgoingRingTimeout: const Duration(milliseconds: 40),
      );
      final placing = c.placeCall(
        conversationId: _convoId,
        peerAccountId: _peerAcc,
        peerUsername: '@peer',
      );
      // The invite is still in flight for longer than the whole ring window.
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(c.current!.status, CallStatus.outgoingRinging,
          reason: 'the timer must not run while the invite is still sending');
      gate.complete();
      await placing;
      // Only now does the callee actually start ringing — and only now does the
      // clock start.
      expect(c.current!.status, CallStatus.outgoingRinging);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(c.current!.status, CallStatus.ended);
      c.dispose();
    });

    test('an invite that never leaves the device fails fast instead of '
        'ringing into the void', () async {
      transport.throwOnSend = true;
      await controller.placeCall(
        conversationId: _convoId,
        peerAccountId: _peerAcc,
        peerUsername: '@peer',
      );
      expect(controller.current!.status, CallStatus.ended);
      expect(controller.current!.endReason, CallEndReason.failed);
    });
  });

  group('from-push placeholder ring (option B)', () {
    test('ringFromPush rings immediately as an awaiting-invite placeholder',
        () {
      controller.ringFromPush(conversationId: _convoId, callerName: '@peer');
      final s = controller.current!;
      expect(s.direction, CallDirection.incoming);
      expect(s.status, CallStatus.incomingRinging);
      expect(s.awaitingInvite, isTrue);
      expect(s.peerUsername, '@peer');
      expect(s.conversationId, _convoId);
      // Nothing on the wire yet — we don't know the callId/device.
      expect(transport.sent, isEmpty);
    });

    test('a matching invite reconciles the placeholder (fills ids, tells caller)',
        () async {
      controller.ringFromPush(conversationId: _convoId, callerName: '@peer');
      await controller.handleSignal(
        invite(),
        fromAccountId: _peerAcc,
        fromDeviceId: 'peer-dev-1',
        conversationId: _convoId,
        peerUsername: '@peer',
      );
      final s = controller.current!;
      expect(s.awaitingInvite, isFalse);
      expect(s.callId, 'call-1');
      expect(s.peerDeviceId, 'peer-dev-1');
      expect(s.peerAccountId, _peerAcc);
      expect(s.status, CallStatus.incomingRinging);
      expect(transport.has(CallSignalType.ringing), isTrue);
    });

    test('answering before the invite queues the accept; reconcile auto-accepts',
        () async {
      controller.ringFromPush(conversationId: _convoId, callerName: '@peer');
      await controller.accept(); // invite not here yet
      expect(controller.current!.status, CallStatus.connecting);
      expect(transport.has(CallSignalType.accept), isFalse); // can't accept yet

      await controller.handleSignal(
        invite(),
        fromAccountId: _peerAcc,
        fromDeviceId: 'peer-dev-1',
        conversationId: _convoId,
        peerUsername: '@peer',
      );
      expect(controller.current!.status, CallStatus.connecting);
      expect(transport.has(CallSignalType.accept), isTrue);
      expect(engine.startedAsCaller, isFalse); // started as callee
    });

    test('declining a push ring ends it and auto-declines the late invite',
        () async {
      controller.ringFromPush(conversationId: _convoId, callerName: '@peer');
      await controller.decline();
      expect(controller.current!.status, CallStatus.ended);
      expect(controller.current!.endReason, CallEndReason.declined);

      transport.sent.clear();
      // The real invite catches up AFTER the decline — must not re-ring.
      await controller.handleSignal(
        invite(),
        fromAccountId: _peerAcc,
        fromDeviceId: 'peer-dev-1',
        conversationId: _convoId,
        peerUsername: '@peer',
      );
      expect(controller.current!.status, CallStatus.ended); // no new ring
      expect(transport.has(CallSignalType.decline), isTrue);
    });

    test('a live real call ignores a push ring', () async {
      await controller.placeCall(
        conversationId: _convoId,
        peerAccountId: _peerAcc,
        peerUsername: '@peer',
      );
      controller.ringFromPush(
          conversationId: '1to1:me-acc:other', callerName: '@other');
      expect(controller.current!.direction, CallDirection.outgoing);
      expect(controller.current!.awaitingInvite, isFalse);
    });

    test('the placeholder times out as missed if no invite ever arrives',
        () async {
      final c = CallController(
        engineFactory: () => engine,
        transport: transport,
        canCall: (_) => true,
        selfDeviceId: () => 'my-dev',
        generateCallId: () => 'call-1',
        clock: () => DateTime.utc(2026, 6, 14, 12),
        pushRingTimeout: const Duration(milliseconds: 20),
      );
      c.ringFromPush(conversationId: _convoId, callerName: '@peer');
      expect(c.current!.awaitingInvite, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(c.current!.status, CallStatus.ended);
      expect(c.current!.endReason, CallEndReason.missed);
      c.dispose();
    });

    test(
        'answering cancels the short "missed" deadline; an answered placeholder '
        'that never reconciles ends as FAILED after the longer answered window',
        () async {
      final c = CallController(
        engineFactory: () => engine,
        transport: transport,
        canCall: (_) => true,
        selfDeviceId: () => 'my-dev',
        generateCallId: () => 'call-1',
        clock: () => DateTime.utc(2026, 6, 14, 12),
        pushRingTimeout: const Duration(milliseconds: 20),
        acceptedAwaitingInviteTimeout: const Duration(milliseconds: 120),
      );
      c.ringFromPush(conversationId: _convoId, callerName: '@peer');
      await c.accept(); // user answers before the invite caught up
      expect(c.current!.status, CallStatus.connecting);

      // Past the short "missed" ring window: answering cancelled it, so the
      // answered call is still alive (NOT dropped as missed).
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(c.current!.status, CallStatus.connecting);

      // Past the longer answered window with still no invite → ends as failed.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(c.current!.status, CallStatus.ended);
      expect(c.current!.endReason, CallEndReason.failed);
      c.dispose();
    });

    test('a cancel arriving before the invite caught up stops the placeholder '
        'ring (matched by conversation, not callId)', () async {
      controller.ringFromPush(conversationId: _convoId, callerName: '@peer');
      expect(controller.current!.awaitingInvite, isTrue);
      // The caller gave up before our invite caught up. The cancel carries the
      // real callId; the placeholder has none yet — it must still match by
      // conversation instead of ringing until the 45s push-ring timeout.
      await controller.handleSignal(
        CallSignal.cancel('call-1'),
        fromAccountId: _peerAcc,
        fromDeviceId: 'peer-dev-1',
        conversationId: _convoId,
      );
      expect(controller.current!.status, CallStatus.ended);
      expect(controller.current!.endReason, CallEndReason.missed);
    });

    test(
        'a cancel tears down a callee that already ACCEPTED but has not '
        'connected (caller gave up before our accept reached it)', () async {
      controller.ringFromPush(conversationId: _convoId, callerName: '@peer');
      await controller.accept(); // we answered; invite hasn't reconciled yet
      expect(controller.current!.status, CallStatus.connecting);
      expect(controller.current!.awaitingInvite, isTrue);

      // The caller's ring timed out before our (slow) accept reached it, so it
      // cancels. A connecting callee must tear down — not hang until its own
      // connect timeout.
      await controller.handleSignal(
        CallSignal.cancel('call-1'),
        fromAccountId: _peerAcc,
        fromDeviceId: 'peer-dev-1',
        conversationId: _convoId,
      );
      expect(controller.current!.status, CallStatus.ended);
      expect(controller.current!.endReason, CallEndReason.cancelled);
    });

    test(
        'a connecting callee IGNORES a stop-ring cancel that names IT as the '
        'winner (the caller\'s answered-elsewhere fan-out must not tear down the '
        'device that just accepted)', () async {
      await controller.handleSignal(invite(),
          fromAccountId: _peerAcc,
          fromDeviceId: 'peer-dev-1',
          conversationId: _convoId,
          peerUsername: '@peer');
      await controller.accept();
      expect(controller.current!.status, CallStatus.connecting);

      // On our accept the caller stops the ring on our account's OTHER devices
      // with a cancel naming the WINNER ('my-dev'). The transport fans it to
      // every device, so it reaches us too — but we ARE the winner, so we keep
      // connecting instead of tearing ourselves down.
      await controller.handleSignal(
        CallSignal.cancel('call-1', exceptDeviceId: 'my-dev'),
        fromAccountId: _peerAcc,
        fromDeviceId: 'peer-dev-1',
        conversationId: _convoId,
      );
      expect(controller.current!.status, CallStatus.connecting);
      expect(controller.current!.isLive, isTrue);
    });

    test(
        'a still-ringing callee DOES stop on a stop-ring cancel naming ANOTHER '
        'device as the winner (a sibling device answered first) — a missed call',
        () async {
      await controller.handleSignal(invite(),
          fromAccountId: _peerAcc,
          fromDeviceId: 'peer-dev-1',
          conversationId: _convoId,
          peerUsername: '@peer');
      expect(controller.current!.status, CallStatus.incomingRinging);

      // Another of our devices ('sibling-dev') accepted first; the caller's
      // stop-ring cancel names that winner. We are NOT the winner → stop ringing.
      // We never answered here, so (like any cancel-while-ringing) it's a missed
      // call.
      await controller.handleSignal(
        CallSignal.cancel('call-1', exceptDeviceId: 'sibling-dev'),
        fromAccountId: _peerAcc,
        fromDeviceId: 'peer-dev-1',
        conversationId: _convoId,
      );
      expect(controller.current!.status, CallStatus.ended);
      expect(controller.current!.endReason, CallEndReason.missed);
    });

    test('a cancel for a DIFFERENT conversation leaves the placeholder ringing',
        () async {
      controller.ringFromPush(conversationId: _convoId, callerName: '@peer');
      await controller.handleSignal(
        CallSignal.cancel('call-1'),
        fromAccountId: 'other-acc',
        fromDeviceId: 'other-dev',
        conversationId: '1to1:me-acc:other',
      );
      // Unrelated teardown — the ring keeps going (no false match by empty id).
      expect(controller.current!.status, CallStatus.incomingRinging);
      expect(controller.current!.awaitingInvite, isTrue);
    });
  });

  group('video call', () {
    test('placeCall(video) starts the engine with video + invites video',
        () async {
      await controller.placeCall(
        conversationId: _convoId,
        peerAccountId: _peerAcc,
        peerUsername: '@peer',
        kind: CallMediaKind.video,
      );
      final s = controller.current!;
      expect(s.mediaKind, CallMediaKind.video);
      expect(s.cameraEnabled, isTrue); // camera on by default
      expect(engine.startedVideo, isTrue);
      final inv = transport.ofType(CallSignalType.invite).single;
      expect(inv.signal.mediaKind, CallMediaKind.video);
    });

    test('an incoming video invite rings as video; accept starts video engine',
        () async {
      await controller.handleSignal(
        CallSignal.invite(
          callId: 'call-1',
          mediaKind: CallMediaKind.video,
          fromDeviceId: 'peer-dev-1',
        ),
        fromAccountId: _peerAcc,
        fromDeviceId: 'peer-dev-1',
        conversationId: _convoId,
        peerUsername: '@peer',
      );
      expect(controller.current!.mediaKind, CallMediaKind.video);

      await controller.accept();
      expect(engine.startedVideo, isTrue);
      expect(engine.startedAsCaller, isFalse);
    });

    test('switchCamera flips the front/back flag and drives the engine',
        () async {
      await controller.placeCall(
        conversationId: _convoId,
        peerAccountId: _peerAcc,
        peerUsername: '@peer',
        kind: CallMediaKind.video,
      );
      expect(controller.current!.usingFrontCamera, isTrue);
      await controller.switchCamera();
      expect(engine.switchCameraCalls, 1);
      expect(controller.current!.usingFrontCamera, isFalse);
    });

    test('setCameraEnabled toggles the engine track and the session flag',
        () async {
      await controller.placeCall(
        conversationId: _convoId,
        peerAccountId: _peerAcc,
        peerUsername: '@peer',
        kind: CallMediaKind.video,
      );
      await controller.setCameraEnabled(false);
      expect(engine.cameraEnabled, isFalse);
      expect(controller.current!.cameraEnabled, isFalse);
    });

    test('camera controls are no-ops on an audio call', () async {
      await controller.placeCall(
        conversationId: _convoId,
        peerAccountId: _peerAcc,
        peerUsername: '@peer',
      );
      await controller.switchCamera();
      await controller.setCameraEnabled(false);
      expect(engine.switchCameraCalls, 0);
      expect(engine.cameraEnabled, isNull);
      // Session is untouched.
      expect(controller.current!.usingFrontCamera, isTrue);
      expect(controller.current!.cameraEnabled, isTrue);
    });

    test('a media-acquisition failure ends the call and sends no invite',
        () async {
      engine.throwOnStart = true; // e.g. camera/mic permission denied
      await controller.placeCall(
        conversationId: _convoId,
        peerAccountId: _peerAcc,
        peerUsername: '@peer',
        kind: CallMediaKind.video,
      );
      expect(controller.current!.status, CallStatus.ended);
      expect(controller.current!.endReason, CallEndReason.failed);
      expect(transport.has(CallSignalType.invite), isFalse);
    });
  });
}
