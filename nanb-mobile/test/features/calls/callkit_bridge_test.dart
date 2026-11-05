import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/core/push/voip_push_channel.dart';
import 'package:nanb_chat/features/calls/call_controller.dart';
import 'package:nanb_chat/features/calls/call_media_engine.dart';
import 'package:nanb_chat/features/calls/call_transport.dart';
import 'package:nanb_chat/features/calls/callkit_bridge.dart';
import 'package:nanb_chat/features/calls/models/call_session.dart';
import 'package:nanb_chat/features/calls/models/call_signal.dart';

/// Stands in for the iOS platform channel. Overriding the concrete class keeps
/// the production seam small — the channel really is just a message pipe.
class _FakeVoipChannel extends VoipPushChannel {
  final _incoming = StreamController<Map<String, String>>.broadcast();
  final _answers = StreamController<void>.broadcast();
  final _ends = StreamController<void>.broadcast();

  bool started = false;
  int endCalls = 0;
  final List<String> callerUpdates = [];

  @override
  Stream<Map<String, String>> get incomingCalls => _incoming.stream;
  @override
  Stream<void> get answers => _answers.stream;
  @override
  Stream<void> get ends => _ends.stream;

  @override
  Future<void> start() async => started = true;

  @override
  Future<void> updateCaller(String name) async => callerUpdates.add(name);

  @override
  Future<void> endCall() async => endCalls++;

  void pushIncoming(Map<String, String> payload) => _incoming.add(payload);
  void tapAnswer() => _answers.add(null);
  void tapEnd() => _ends.add(null);

  Future<void> settle() => Future<void>.delayed(Duration.zero);
}

class _FakeEngine implements CallMediaEngine {
  final _ice = StreamController<Map<String, dynamic>>.broadcast();
  final _conn = StreamController<CallConnectionState>.broadcast();

  @override
  Stream<Map<String, dynamic>> get localIceCandidates => _ice.stream;
  @override
  Stream<CallConnectionState> get connectionState => _conn.stream;
  @override
  Future<void> start({required bool isCaller, bool video = false}) async {}
  @override
  Future<String> createOffer() async => 'OFFER';
  @override
  Future<String> createAnswer(String remoteOffer) async => 'ANSWER';
  @override
  Future<void> acceptAnswer(String remoteAnswer) async {}
  @override
  Future<String> restartIce() async => 'OFFER2';
  @override
  Future<void> addRemoteIce(Map<String, dynamic> candidate) async {}
  @override
  Future<void> setMicMuted(bool muted) async {}
  @override
  Future<void> setSpeakerOn(bool on) async {}
  @override
  Future<void> switchCamera() async {}
  @override
  Future<void> setCameraEnabled(bool enabled) async {}
  @override
  Future<void> close() async {}
}

class _SilentTransport implements CallTransport {
  final List<CallSignal> sent = [];
  @override
  Future<void> sendInvite({
    required String toAccountId,
    required CallSignal signal,
  }) async =>
      sent.add(signal);
  @override
  Future<void> sendToDevice({
    required String toAccountId,
    required String toDeviceId,
    required CallSignal signal,
  }) async =>
      sent.add(signal);
  @override
  Future<void> sendToAllDevices({
    required String toAccountId,
    required CallSignal signal,
  }) async =>
      sent.add(signal);

  @override
  Future<void> sendToOwnDevices({
    required String peerAccountId,
    required CallSignal signal,
  }) async {}
}

const _convoId = '1to1:me-acc:peer-acc';

void main() {
  late _FakeVoipChannel channel;
  late _SilentTransport transport;
  late CallController controller;
  late CallKitBridge bridge;
  late bool callable;
  late String? resolved;

  Future<void> buildBridge() async {
    bridge = CallKitBridge(
      channel: channel,
      controller: () => controller,
      resolveConversationId: (_) async => resolved,
      resolveCallerName: (_) async => '@peer',
      shouldRing: (_) => callable,
    );
    await bridge.start();
  }

  setUp(() async {
    channel = _FakeVoipChannel();
    transport = _SilentTransport();
    callable = true;
    resolved = _convoId;
    controller = CallController(
      engineFactory: _FakeEngine.new,
      transport: transport,
      canCall: (_) => true,
      selfDeviceId: () => 'my-dev',
      generateCallId: () => 'call-1',
      clock: () => DateTime.utc(2026, 8, 19, 12),
    );
    await buildBridge();
  });

  tearDown(() async {
    await bridge.dispose();
    controller.dispose();
  });

  test('start attaches to the channel (which replays buffered events)', () {
    expect(channel.started, isTrue);
  });

  test('an incoming VoIP push rings the state machine for the RESOLVED '
      'conversation', () async {
    channel.pushIncoming({'event': 'incomingCall', 'sealed_payload': 'x'});
    await channel.settle();

    final s = controller.current!;
    expect(s.status, CallStatus.incomingRinging);
    expect(s.conversationId, _convoId);
    expect(s.awaitingInvite, isTrue, reason: 'the real invite reconciles later');
    // The push is content-blind, so CallKit first showed a generic name; the
    // peer's real name has to be pushed back to the system UI.
    expect(channel.callerUpdates, ['@peer']);
  });

  // The phone is ALREADY ringing by the time Dart hears about it (iOS requires
  // the native side to report before running any app code), so every "we won't
  // ring for this" decision has to be mirrored back or a phantom system call
  // stays on screen with nothing behind it.
  test('an unresolvable push dismisses the system call instead of leaving a '
      'phantom ring', () async {
    resolved = null;
    channel.pushIncoming({'event': 'incomingCall'});
    await channel.settle();

    expect(controller.current, isNull);
    expect(channel.endCalls, 1);
  });

  test('a push for a non-callable conversation dismisses the system call',
      () async {
    callable = false;
    channel.pushIncoming({'event': 'incomingCall', 'sealed_payload': 'x'});
    await channel.settle();

    expect(controller.current, isNull);
    expect(channel.endCalls, 1);
  });

  test('answering on the system UI accepts the call', () async {
    channel.pushIncoming({'event': 'incomingCall', 'sealed_payload': 'x'});
    await channel.settle();

    channel.tapAnswer();
    await channel.settle();

    expect(controller.current!.status, CallStatus.connecting);
  });

  // THE cold-launch path: with the app killed, the native side buffers the
  // ring AND the answer tap, then replays them back-to-back the moment the
  // engine attaches. Resolving the conversation is async, so without ordering
  // the answer landed on a state machine that had no session yet and was
  // dropped — "I answered from the lock screen and nothing happened".
  test('an answer replayed immediately after the ring still connects',
      () async {
    channel.pushIncoming({'event': 'incomingCall', 'sealed_payload': 'x'});
    channel.tapAnswer(); // no await between them — the replay is back-to-back
    await channel.settle();
    await channel.settle();

    expect(controller.current!.status, CallStatus.connecting);
  });

  test('ending on the system UI while ringing declines', () async {
    channel.pushIncoming({'event': 'incomingCall', 'sealed_payload': 'x'});
    await channel.settle();

    channel.tapEnd();
    await channel.settle();

    expect(controller.current!.status, CallStatus.ended);
    expect(controller.current!.endReason, CallEndReason.declined);
  });

  // The system call UI is already gone when this fires, so the bridge itself
  // must not try to end it again. (In the app, onCallEnded still runs and calls
  // endCall — the native side no-ops because it has already cleared the call.)
  test('ending on the system UI does not itself call back into it', () async {
    channel.pushIncoming({'event': 'incomingCall', 'sealed_payload': 'x'});
    await channel.settle();

    channel.tapEnd();
    await channel.settle();

    expect(channel.endCalls, 0);
  });

  // The in-app ringtone must stay silent while CallKit sounds its own, or the
  // user hears two out-of-phase rings.
  test('systemIsRinging tracks the CallKit ring', () async {
    expect(bridge.systemIsRinging, isFalse);

    channel.pushIncoming({'event': 'incomingCall', 'sealed_payload': 'x'});
    await channel.settle();
    expect(bridge.systemIsRinging, isTrue);

    await bridge.onAppCallEnded();
    expect(bridge.systemIsRinging, isFalse);
  });

  test('an app-side end dismisses the system call UI', () async {
    channel.pushIncoming({'event': 'incomingCall', 'sealed_payload': 'x'});
    await channel.settle();

    await bridge.onAppCallEnded();

    expect(channel.endCalls, 1);
  });
}
