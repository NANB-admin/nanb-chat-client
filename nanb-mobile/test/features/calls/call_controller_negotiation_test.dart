import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/features/calls/call_controller.dart';
import 'package:nanb_chat/features/calls/call_media_engine.dart';
import 'package:nanb_chat/features/calls/models/call_session.dart';
import 'package:nanb_chat/features/calls/models/call_signal.dart';

import 'support/recording_call_transport.dart';
import 'support/scripted_call_engine.dart';

// Call-setup reliability: the SDP/ICE handshake must neither lose signals to
// ordering races nor hang when one is lost in transit.

const _convoId = '1to1:me-acc:peer-acc';
const _peerAcc = 'peer-acc';
const _peerDev = 'peer-dev-1';

final _cand1 = {'candidate': 'cand-1', 'sdpMid': '0', 'sdpMLineIndex': 0};
final _cand2 = {'candidate': 'cand-2', 'sdpMid': '0', 'sdpMLineIndex': 0};
final _cand3 = {'candidate': 'cand-3', 'sdpMid': '0', 'sdpMLineIndex': 0};

void main() {
  late ScriptedCallEngine engine;
  late RecordingCallTransport transport;
  final controllers = <CallController>[];

  setUp(() {
    engine = ScriptedCallEngine();
    transport = RecordingCallTransport();
  });

  tearDown(() {
    for (final c in controllers) {
      c.dispose();
    }
    controllers.clear();
  });

  CallController build({
    String callId = 'call-1',
    Duration connectRetryInterval = const Duration(minutes: 5),
  }) {
    final c = CallController(
      engineFactory: () => engine,
      transport: transport,
      canCall: (_) => true,
      selfDeviceId: () => 'my-dev',
      generateCallId: () => callId,
      clock: () => DateTime.utc(2026, 6, 14, 12),
      connectRetryInterval: connectRetryInterval,
      connectTimeout: const Duration(minutes: 10),
    );
    controllers.add(c);
    return c;
  }

  Future<void> peer(CallController c, CallSignal sig) => c.handleSignal(
        sig,
        fromAccountId: _peerAcc,
        fromDeviceId: _peerDev,
        conversationId: _convoId,
        peerUsername: '@peer',
      );

  CallSignal invite(String callId) => CallSignal.invite(
        callId: callId,
        mediaKind: CallMediaKind.audio,
        fromDeviceId: _peerDev,
      );

  /// Caller side, up to "offer sent".
  Future<void> placeAndGetAccepted(CallController c) async {
    await c.placeCall(
      conversationId: _convoId,
      peerAccountId: _peerAcc,
      peerUsername: '@peer',
    );
    await peer(c, CallSignal.accept(callId: 'call-1', fromDeviceId: _peerDev));
    await pumpEventQueue();
  }

  /// Callee side, up to "accept sent".
  Future<void> ringAndAccept(CallController c) async {
    await peer(c, invite('call-1'));
    await c.accept();
    await pumpEventQueue();
  }

  group('engine start race', () {
    test('an offer arriving while the callee engine is still starting is '
        'answered once it has started (not dropped)', () async {
      final c = build();
      engine.startGate = Completer<void>();
      await peer(c, invite('call-1'));
      unawaited(c.accept());
      await pumpEventQueue();

      final offerHandled =
          peer(c, CallSignal.offer(callId: 'call-1', sdp: 'OFFER_SDP'));
      await pumpEventQueue();
      engine.startGate!.complete();
      await offerHandled;

      expect(transport.ofType(CallSignalType.answer), hasLength(1));
    });
  });

  group('trickle ICE ordering', () {
    test('caller candidates gathered while creating the offer are sent after '
        'the offer', () async {
      final c = build();
      engine.gatherOnLocalDescription = [_cand1];
      await placeAndGetAccepted(c);

      final offerAt = transport.firstIndexOf(CallSignalType.offer);
      final iceAt = transport.firstIndexOf(CallSignalType.ice);
      expect(iceAt, greaterThan(offerAt));
    });

    test('callee candidates gathered while creating the answer are sent after '
        'the answer', () async {
      final c = build();
      engine.gatherOnLocalDescription = [_cand1];
      await ringAndAccept(c);
      await peer(c, CallSignal.offer(callId: 'call-1', sdp: 'OFFER_SDP'));
      await pumpEventQueue();

      final answerAt = transport.firstIndexOf(CallSignalType.answer);
      final iceAt = transport.firstIndexOf(CallSignalType.ice);
      expect(iceAt, greaterThan(answerAt));
    });

    test('a remote candidate that arrives before the offer is applied once the '
        'offer is', () async {
      final c = build();
      await ringAndAccept(c);
      await peer(c, CallSignal.ice(callId: 'call-1', candidate: _cand1));
      await peer(c, CallSignal.offer(callId: 'call-1', sdp: 'OFFER_SDP'));

      expect(engine.rejectedRemoteIce, isEmpty);
      expect(engine.appliedRemoteIce, [_cand1]);
    });

    test('a remote candidate that arrives before the answer is applied once the '
        'answer is', () async {
      final c = build();
      await placeAndGetAccepted(c);
      await peer(c, CallSignal.ice(callId: 'call-1', candidate: _cand1));
      await peer(c, CallSignal.answer(callId: 'call-1', sdp: 'ANSWER_SDP'));

      expect(engine.rejectedRemoteIce, isEmpty);
      expect(engine.appliedRemoteIce, [_cand1]);
    });

    test('every candidate in a batched ice signal is applied', () async {
      final c = build();
      await placeAndGetAccepted(c);
      await peer(c, CallSignal.answer(callId: 'call-1', sdp: 'ANSWER_SDP'));
      await peer(c,
          CallSignal.iceBatch(callId: 'call-1', candidates: [_cand1, _cand2]));

      expect(engine.appliedRemoteIce, [_cand1, _cand2]);
    });
  });

  group('candidate batching', () {
    test('candidates gathered while a candidate send is in flight leave as one '
        'batch', () async {
      final c = build();
      await placeAndGetAccepted(c);
      final gate = Completer<void>();
      transport.gates[CallSignalType.ice] = gate;

      engine.emitIce(_cand1); // goes out alone, then stalls on the lock
      await pumpEventQueue();
      engine.emitIce(_cand2);
      engine.emitIce(_cand3);
      gate.complete();
      await pumpEventQueue();

      final ice = transport.ofType(CallSignalType.ice);
      expect(ice, hasLength(2));
      expect(ice[1].iceCandidates, [_cand2, _cand3]);
    });
  });

  group('connect retry (lost signals must not hang the call)', () {
    test('the caller re-sends the same offer when no answer arrives', () async {
      final c = build(connectRetryInterval: const Duration(milliseconds: 20));
      await placeAndGetAccepted(c);
      await Future<void>.delayed(const Duration(milliseconds: 35));

      final offers = transport.ofType(CallSignalType.offer);
      expect(offers.length, greaterThanOrEqualTo(2));
      expect(offers.map((o) => (o.sdp, o.seq)).toSet(), {('OFFER_SDP', 1)});
    });

    test('a failed first offer send is retried', () async {
      final c = build(connectRetryInterval: const Duration(milliseconds: 20));
      transport.failTypes.add(CallSignalType.offer);
      await placeAndGetAccepted(c);
      transport.failTypes.clear();
      await Future<void>.delayed(const Duration(milliseconds: 35));

      expect(transport.ofType(CallSignalType.offer).length,
          greaterThanOrEqualTo(2));
    });

    test('the caller restarts ICE when answered but never connected', () async {
      final c = build(connectRetryInterval: const Duration(milliseconds: 20));
      await placeAndGetAccepted(c);
      await peer(c, CallSignal.answer(callId: 'call-1', sdp: 'ANSWER_SDP'));
      await Future<void>.delayed(const Duration(milliseconds: 35));

      expect(engine.restartIceCalls, 1);
      expect(transport.ofType(CallSignalType.offer).last.seq, 2);
    });

    test('the callee re-sends its accept when no offer arrives', () async {
      final c = build(connectRetryInterval: const Duration(milliseconds: 20));
      await ringAndAccept(c);
      await Future<void>.delayed(const Duration(milliseconds: 35));

      expect(transport.ofType(CallSignalType.accept).length,
          greaterThanOrEqualTo(2));
    });

    test('a duplicate accept from the pinned device gets the offer again, not '
        'a cancel', () async {
      final c = build();
      await placeAndGetAccepted(c);
      await peer(c, CallSignal.accept(callId: 'call-1', fromDeviceId: _peerDev));
      await pumpEventQueue();

      expect(transport.ofType(CallSignalType.offer), hasLength(2));
      expect(
        transport.sent.where((s) =>
            s.$3.type == CallSignalType.cancel && s.$1 == 'device'),
        isEmpty,
      );
    });

    test('no retry fires once the call has connected', () async {
      final c = build(connectRetryInterval: const Duration(milliseconds: 20));
      await placeAndGetAccepted(c);
      engine.emitConn(CallConnectionState.connected);
      await pumpEventQueue();
      await Future<void>.delayed(const Duration(milliseconds: 35));

      expect(transport.ofType(CallSignalType.offer), hasLength(1));
    });
  });

  group('accept from a device that does not know its own id', () {
    // A freshly signed-in callee can send its accept before its controller has
    // learned its own device id, so the self-declared field arrives empty. The
    // transport-level sender id is the authoritative one.
    test('the caller still sends the offer, to the authenticated sender device',
        () async {
      final c = build();
      await c.placeCall(
        conversationId: _convoId,
        peerAccountId: _peerAcc,
        peerUsername: '@peer',
      );
      await peer(c, CallSignal.accept(callId: 'call-1', fromDeviceId: ''));
      await pumpEventQueue();

      final offerSends = transport.sent.where(
          (s) => s.$3.type == CallSignalType.offer && s.$1 == 'device');
      expect(offerSends, hasLength(1));
      expect(offerSends.single.$2, _peerDev);
    });
  });

  group('offer/answer de-duplication', () {
    test('the callee answers a duplicate offer from cache without '
        'renegotiating', () async {
      final c = build();
      await ringAndAccept(c);
      await peer(c, CallSignal.offer(callId: 'call-1', sdp: 'OFFER_SDP'));
      await peer(c, CallSignal.offer(callId: 'call-1', sdp: 'OFFER_SDP'));

      expect(engine.createAnswerCalls, 1);
      expect(transport.ofType(CallSignalType.answer), hasLength(2));
    });

    test('the callee echoes the offer number on its answer', () async {
      final c = build();
      await ringAndAccept(c);
      await peer(c, CallSignal.offer(callId: 'call-1', sdp: 'OFFER_SDP', seq: 7));

      expect(transport.ofType(CallSignalType.answer).single.seq, 7);
    });

    test('the caller applies a duplicate answer only once', () async {
      final c = build();
      await placeAndGetAccepted(c);
      await peer(c, CallSignal.answer(callId: 'call-1', sdp: 'ANSWER_SDP'));
      await peer(c, CallSignal.answer(callId: 'call-1', sdp: 'ANSWER_SDP'));

      expect(engine.acceptAnswerCalls, 1);
    });

    test('the caller ignores an answer to a superseded offer', () async {
      final c = build();
      await placeAndGetAccepted(c);
      engine.emitConn(CallConnectionState.failed); // → ICE restart, offer #2
      await pumpEventQueue();
      await peer(
          c, CallSignal.answer(callId: 'call-1', sdp: 'ANSWER_SDP', seq: 1));

      expect(engine.acceptAnswerCalls, 0);
    });
  });

  group('invites from the same peer', () {
    test('glare: the call with the larger id yields and rings the peer\'s',
        () async {
      final c = build(callId: 'call-b');
      await c.placeCall(
        conversationId: _convoId,
        peerAccountId: _peerAcc,
        peerUsername: '@peer',
      );
      await peer(c, invite('call-a'));

      expect(c.current!.callId, 'call-a');
      expect(c.current!.status, CallStatus.incomingRinging);
    });

    test('glare: the call with the smaller id keeps ringing and does not '
        'busy-decline the peer', () async {
      final c = build(callId: 'call-a');
      await c.placeCall(
        conversationId: _convoId,
        peerAccountId: _peerAcc,
        peerUsername: '@peer',
      );
      await peer(c, invite('call-b'));

      expect(c.current!.callId, 'call-a');
      expect(transport.ofType(CallSignalType.decline), isEmpty);
    });

    test('a re-dial supersedes a stuck connecting attempt instead of bouncing '
        'off busy', () async {
      final c = build();
      await ringAndAccept(c); // call-1 stuck in connecting
      await peer(c, invite('call-2'));

      expect(c.current!.callId, 'call-2');
      expect(c.current!.status, CallStatus.incomingRinging);
    });

    test('a re-delivered invite for the ringing call is not busy-declined',
        () async {
      final c = build();
      await peer(c, invite('call-1'));
      await peer(c, invite('call-1'));

      expect(transport.ofType(CallSignalType.decline), isEmpty);
    });

    test('an invite from the peer during an ACTIVE call is still declined as '
        'busy', () async {
      final c = build();
      await ringAndAccept(c);
      await peer(c, CallSignal.offer(callId: 'call-1', sdp: 'OFFER_SDP'));
      engine.emitConn(CallConnectionState.connected);
      await pumpEventQueue();
      await peer(c, invite('call-2'));

      expect(c.current!.callId, 'call-1');
      expect(transport.ofType(CallSignalType.decline).single.reason,
          CallEndReason.busy);
    });
  });
}
