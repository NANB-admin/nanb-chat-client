import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/app/providers.dart';
import 'package:nanb_chat/app/theme.dart';
import 'package:nanb_chat/features/calls/call_controller.dart';
import 'package:nanb_chat/features/calls/call_media_engine.dart';
import 'package:nanb_chat/features/calls/call_overlay.dart';
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

class _NoopTransport implements CallTransport {
  @override
  Future<void> sendInvite({required toAccountId, required signal}) async {}
  @override
  Future<void> sendToDevice(
      {required toAccountId, required toDeviceId, required signal}) async {}
  @override
  Future<void> sendToAllDevices(
      {required toAccountId, required signal}) async {}
  @override
  Future<void> sendToOwnDevices(
      {required peerAccountId, required signal}) async {}
}

void main() {
  late CallController controller;

  setUp(() {
    controller = CallController(
      engineFactory: () => _FakeEngine(),
      transport: _NoopTransport(),
      canCall: (_) => true,
      selfDeviceId: () => 'my-dev',
      generateCallId: () => 'call-1',
      clock: () => DateTime.utc(2026, 6, 14, 12),
    );
  });

  // The ChangeNotifierProvider disposes the controller on ProviderScope
  // teardown, so we don't dispose it here (that would double-dispose).

  Widget wrap(FocusNode composerFocus) => ProviderScope(
        overrides: [callControllerProvider.overrideWith((ref) => controller)],
        child: MaterialApp(
          theme: buildLightTheme(),
          home: Scaffold(
            // A full-screen child (as the real routed page is) so the overlay
            // Stack fills the viewport rather than collapsing to the field.
            body: CallOverlay(
              child: Center(child: TextField(focusNode: composerFocus)),
            ),
          ),
        ),
      );

  Future<void> ringIncoming() => controller.handleSignal(
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

  testWidgets('an incoming call retracts the focused (open) keyboard',
      (tester) async {
    final composerFocus = FocusNode();
    addTearDown(composerFocus.dispose);
    await tester.pumpWidget(wrap(composerFocus));

    // The user was typing in the chat: the composer holds focus (keyboard up).
    composerFocus.requestFocus();
    await tester.pump();
    expect(composerFocus.hasFocus, isTrue);

    // A call rings in over the thread.
    await ringIncoming();
    await tester.pump();

    // Focus was dropped, so iOS retracts the keyboard and the Accept/Decline
    // controls are no longer hidden behind it.
    expect(composerFocus.hasFocus, isFalse);
  });

  Future<void> answer(WidgetTester tester) async {
    await ringIncoming();
    await tester.pump();
    await controller.accept();
    await tester.pump();
  }

  testWidgets('an answered call can be minimized to a banner', (tester) async {
    await tester.pumpWidget(wrap(FocusNode()));
    await answer(tester);

    await tester.tap(find.byKey(const ValueKey('call-minimize')));
    await tester.pump();

    expect(find.byKey(const ValueKey('call-banner')), findsOneWidget);
  });

  testWidgets('the app underneath is usable while the call is minimized',
      (tester) async {
    final focus = FocusNode();
    addTearDown(focus.dispose);
    await tester.pumpWidget(wrap(focus));
    await answer(tester);
    await tester.tap(find.byKey(const ValueKey('call-minimize')));
    await tester.pump();

    await tester.tap(find.byType(TextField));
    await tester.pump();

    expect(focus.hasFocus, isTrue);
  });

  testWidgets('tapping the banner returns to the full call screen',
      (tester) async {
    await tester.pumpWidget(wrap(FocusNode()));
    await answer(tester);
    await tester.tap(find.byKey(const ValueKey('call-minimize')));
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('call-banner')));
    await tester.pump();

    expect(find.byKey(const ValueKey('call-banner')), findsNothing);
  });

  testWidgets('ending the call from the banner hangs up', (tester) async {
    await tester.pumpWidget(wrap(FocusNode()));
    await answer(tester);
    await tester.tap(find.byKey(const ValueKey('call-minimize')));
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('call-banner-end')));
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump();

    expect(controller.current?.status, CallStatus.ended);
    // Let the overlay's "Call ended" dismiss timer fire.
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('a ringing inbound call cannot be minimized', (tester) async {
    await tester.pumpWidget(wrap(FocusNode()));
    await ringIncoming();
    await tester.pump();

    expect(find.byKey(const ValueKey('call-minimize')), findsNothing);
  });
}
