import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/app/providers.dart';
import 'package:nanb_chat/app/theme.dart';
import 'package:nanb_chat/features/calls/call_controller.dart';
import 'package:nanb_chat/features/calls/call_media_engine.dart';
import 'package:nanb_chat/features/calls/call_screen.dart';
import 'package:nanb_chat/features/calls/call_transport.dart';
import 'package:nanb_chat/features/calls/models/call_session.dart';
import 'package:nanb_chat/features/calls/models/call_signal.dart';

class _FakeEngine implements CallMediaEngine {
  final _ice = StreamController<Map<String, dynamic>>.broadcast();
  final _conn = StreamController<CallConnectionState>.broadcast();
  @override
  Future<void> start({required bool isCaller, bool video = false}) async {}
  @override
  Future<String> createOffer() async => 'OFFER';
  @override
  Future<String> createAnswer(String remoteOffer) async => 'ANSWER';
  @override
  Future<String> restartIce() async => 'RESTART_OFFER';
  @override
  Future<void> acceptAnswer(String remoteAnswer) async {}
  @override
  Future<void> addRemoteIce(Map<String, dynamic> candidate) async {}
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
}

class _RecordingTransport implements CallTransport {
  final List<CallSignal> sent = [];
  @override
  Future<void> sendInvite({required toAccountId, required signal}) async =>
      sent.add(signal);
  @override
  Future<void> sendToDevice(
          {required toAccountId, required toDeviceId, required signal}) async =>
      sent.add(signal);
  @override
  Future<void> sendToAllDevices({required toAccountId, required signal}) async =>
      sent.add(signal);
  @override
  Future<void> sendToOwnDevices({required peerAccountId, required signal}) async {}
  bool has(CallSignalType t) => sent.any((s) => s.type == t);
}

CallSession _session(
  CallStatus status, {
  CallDirection dir = CallDirection.incoming,
  CallMediaKind kind = CallMediaKind.audio,
}) =>
    CallSession(
      callId: 'call-1',
      conversationId: '1to1:me:peer',
      peerAccountId: 'peer-acc',
      peerUsername: '@peer',
      peerDeviceId: 'peer-dev',
      direction: dir,
      status: status,
      mediaKind: kind,
      startedAt: DateTime.utc(2026, 6, 14, 12),
      connectedAt:
          status == CallStatus.active ? DateTime.utc(2026, 6, 14, 12) : null,
    );

void main() {
  late _RecordingTransport transport;
  late CallController controller;

  setUp(() {
    transport = _RecordingTransport();
    controller = CallController(
      engineFactory: () => _FakeEngine(),
      transport: transport,
      canCall: (_) => true,
      selfDeviceId: () => 'my-dev',
      generateCallId: () => 'call-1',
      clock: () => DateTime.utc(2026, 6, 14, 12),
    );
  });

  // The ChangeNotifierProvider disposes the controller on ProviderScope
  // teardown, so we don't dispose it here (that would double-dispose).

  Widget wrap(CallSession session) => ProviderScope(
        overrides: [callControllerProvider.overrideWith((ref) => controller)],
        child: MaterialApp(
          theme: buildLightTheme(),
          home: CallScreen(session: session),
        ),
      );

  testWidgets('incoming call shows accept + decline', (tester) async {
    await tester.pumpWidget(wrap(_session(CallStatus.incomingRinging)));
    expect(find.text('@peer'), findsOneWidget);
    expect(find.text('Incoming call'), findsOneWidget);
    expect(find.byKey(const ValueKey('call-accept')), findsOneWidget);
    expect(find.byKey(const ValueKey('call-decline')), findsOneWidget);
  });

  testWidgets('outgoing call shows Calling… + a single End button',
      (tester) async {
    await tester.pumpWidget(
        wrap(_session(CallStatus.outgoingRinging, dir: CallDirection.outgoing)));
    expect(find.text('Calling…'), findsOneWidget);
    expect(find.byKey(const ValueKey('call-end')), findsOneWidget);
    expect(find.byKey(const ValueKey('call-accept')), findsNothing);
  });

  testWidgets('active call shows mute / end / speaker controls', (tester) async {
    await tester.pumpWidget(wrap(_session(CallStatus.active)));
    expect(find.byKey(const ValueKey('call-mute')), findsOneWidget);
    expect(find.byKey(const ValueKey('call-end')), findsOneWidget);
    expect(find.byKey(const ValueKey('call-speaker')), findsOneWidget);
    // A running duration (m:ss) is shown as the status line.
    expect(find.textContaining(RegExp(r'\d+:\d\d')), findsOneWidget);
  });

  testWidgets('active video call shows camera + flip controls', (tester) async {
    await tester.pumpWidget(
        wrap(_session(CallStatus.active, kind: CallMediaKind.video)));
    expect(find.byKey(const ValueKey('call-mute')), findsOneWidget);
    expect(find.byKey(const ValueKey('call-camera')), findsOneWidget);
    expect(find.byKey(const ValueKey('call-flip')), findsOneWidget);
    expect(find.byKey(const ValueKey('call-end')), findsOneWidget);
    expect(find.byKey(const ValueKey('call-speaker')), findsOneWidget);
  });

  testWidgets('incoming video call labels the status as video', (tester) async {
    await tester.pumpWidget(
        wrap(_session(CallStatus.incomingRinging, kind: CallMediaKind.video)));
    expect(find.text('Incoming video call'), findsOneWidget);
    expect(find.byKey(const ValueKey('call-accept')), findsOneWidget);
    expect(find.byKey(const ValueKey('call-decline')), findsOneWidget);
    // No camera/flip controls until the call is active.
    expect(find.byKey(const ValueKey('call-camera')), findsNothing);
  });

  testWidgets('audio active call has no camera/flip controls', (tester) async {
    await tester.pumpWidget(wrap(_session(CallStatus.active)));
    expect(find.byKey(const ValueKey('call-camera')), findsNothing);
    expect(find.byKey(const ValueKey('call-flip')), findsNothing);
  });

  testWidgets('tapping Decline on an incoming call sends a decline + ends',
      (tester) async {
    // Drive the controller into the incoming-ringing state so its buttons act.
    await controller.handleSignal(
      CallSignal.invite(
        callId: 'call-1',
        mediaKind: CallMediaKind.audio,
        fromDeviceId: 'peer-dev',
      ),
      fromAccountId: 'peer-acc',
      fromDeviceId: 'peer-dev',
      conversationId: '1to1:me:peer',
      peerUsername: '@peer',
    );
    transport.sent.clear();

    await tester.pumpWidget(wrap(controller.current!));
    await tester.tap(find.byKey(const ValueKey('call-decline')));
    await tester.pump();

    expect(transport.has(CallSignalType.decline), isTrue);
    expect(controller.current!.status, CallStatus.ended);
  });
}
