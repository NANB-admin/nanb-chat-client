import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/features/calls/models/call_signal.dart';

void main() {
  group('CallSignal encode/decode round-trips', () {
    test('invite', () {
      final s = CallSignal.invite(
        callId: 'c1',
        mediaKind: CallMediaKind.audio,
        fromDeviceId: 'dev-a',
      );
      final d = CallSignal.tryDecode(s.encode())!;
      expect(d.type, CallSignalType.invite);
      expect(d.callId, 'c1');
      expect(d.mediaKind, CallMediaKind.audio);
      expect(d.fromDeviceId, 'dev-a');
    });

    test('video invite preserves the video media kind', () {
      final s = CallSignal.invite(
        callId: 'c1',
        mediaKind: CallMediaKind.video,
        fromDeviceId: 'dev-a',
      );
      final d = CallSignal.tryDecode(s.encode())!;
      expect(d.type, CallSignalType.invite);
      expect(d.mediaKind, CallMediaKind.video);
    });

    test('ringing / cancel carry just the call id', () {
      for (final s in [CallSignal.ringing('c1'), CallSignal.cancel('c1')]) {
        final d = CallSignal.tryDecode(s.encode())!;
        expect(d.callId, 'c1');
        expect(d.type, s.type);
      }
    });

    test('a give-up cancel carries no winner; a stop-ring cancel carries the '
        'winning device', () {
      final giveUp = CallSignal.tryDecode(CallSignal.cancel('c1').encode())!;
      expect(giveUp.type, CallSignalType.cancel);
      expect(giveUp.fromDeviceId, isNull);

      final stopRing = CallSignal.tryDecode(
        CallSignal.cancel('c1', exceptDeviceId: 'dev-b').encode(),
      )!;
      expect(stopRing.type, CallSignalType.cancel);
      expect(stopRing.fromDeviceId, 'dev-b');
    });

    test('accept carries the accepting device', () {
      final d = CallSignal.tryDecode(
        CallSignal.accept(callId: 'c1', fromDeviceId: 'dev-b').encode(),
      )!;
      expect(d.type, CallSignalType.accept);
      expect(d.fromDeviceId, 'dev-b');
    });

    test('decline defaults to declined; busy round-trips', () {
      expect(
        CallSignal.tryDecode(CallSignal.decline('c1').encode())!.reason,
        CallEndReason.declined,
      );
      expect(
        CallSignal.tryDecode(
          CallSignal.decline('c1', reason: CallEndReason.busy).encode(),
        )!
            .reason,
        CallEndReason.busy,
      );
    });

    test('offer / answer carry the SDP', () {
      final o = CallSignal.tryDecode(
        CallSignal.offer(callId: 'c1', sdp: 'v=0...OFFER').encode(),
      )!;
      expect(o.type, CallSignalType.offer);
      expect(o.sdp, 'v=0...OFFER');
      final a = CallSignal.tryDecode(
        CallSignal.answer(callId: 'c1', sdp: 'v=0...ANSWER').encode(),
      )!;
      expect(a.type, CallSignalType.answer);
      expect(a.sdp, 'v=0...ANSWER');
    });

    test('ice carries the candidate map', () {
      final cand = {
        'candidate': 'candidate:1 1 UDP ...',
        'sdpMid': '0',
        'sdpMLineIndex': 0,
      };
      final d = CallSignal.tryDecode(
        CallSignal.ice(callId: 'c1', candidate: cand).encode(),
      )!;
      expect(d.type, CallSignalType.ice);
      expect(d.candidate, cand);
    });

    test('hangup defaults to hangup reason', () {
      final d = CallSignal.tryDecode(CallSignal.hangup('c1').encode())!;
      expect(d.type, CallSignalType.hangup);
      expect(d.reason, CallEndReason.hangup);
    });
  });

  group('CallSignal batching + offer numbering', () {
    final c1 = {'candidate': 'c1', 'sdpMid': '0', 'sdpMLineIndex': 0};
    final c2 = {'candidate': 'c2', 'sdpMid': '0', 'sdpMLineIndex': 0};

    test('a batched ice signal round-trips every candidate', () {
      final d = CallSignal.tryDecode(
        CallSignal.iceBatch(callId: 'c1', candidates: [c1, c2]).encode(),
      )!;
      expect(d.iceCandidates, [c1, c2]);
    });

    test('a batched ice signal still carries its first candidate under the '
        'legacy single-candidate key', () {
      final d = CallSignal.tryDecode(
        CallSignal.iceBatch(callId: 'c1', candidates: [c1, c2]).encode(),
      )!;
      expect(d.candidate, c1);
    });

    test('a legacy single-candidate ice signal exposes it as a one-element '
        'list', () {
      final d = CallSignal.tryDecode(
        CallSignal.ice(callId: 'c1', candidate: c1).encode(),
      )!;
      expect(d.iceCandidates, [c1]);
    });

    test('an offer round-trips its number', () {
      final d = CallSignal.tryDecode(
        CallSignal.offer(callId: 'c1', sdp: 'SDP', seq: 3).encode(),
      )!;
      expect(d.seq, 3);
    });

    test('an answer round-trips the echoed offer number', () {
      final d = CallSignal.tryDecode(
        CallSignal.answer(callId: 'c1', sdp: 'SDP', seq: 3).encode(),
      )!;
      expect(d.seq, 3);
    });

    test('an answer from a peer that predates numbering decodes with no '
        'number', () {
      final d = CallSignal.tryDecode(
        '{"_call":"answer","cid":"c1","sdp":"SDP"}',
      )!;
      expect(d.seq, isNull);
    });
  });

  group('CallSignal.tryDecode fast-rejects non-signals', () {
    test('plain text / empty', () {
      expect(CallSignal.tryDecode('hello'), isNull);
      expect(CallSignal.tryDecode(''), isNull);
    });

    test('JSON without _call', () {
      expect(CallSignal.tryDecode('{"_control":"receipt"}'), isNull);
      expect(CallSignal.tryDecode('{"foo":1}'), isNull);
    });

    test('unknown _call type', () {
      expect(CallSignal.tryDecode('{"_call":"frobnicate","cid":"c1"}'), isNull);
    });

    test('missing / empty call id', () {
      expect(CallSignal.tryDecode('{"_call":"ringing"}'), isNull);
      expect(CallSignal.tryDecode('{"_call":"ringing","cid":""}'), isNull);
    });

    test('offer without sdp', () {
      expect(CallSignal.tryDecode('{"_call":"offer","cid":"c1"}'), isNull);
    });

    test('a chat MessageControl body is not mistaken for a call', () {
      expect(
        CallSignal.tryDecode('{"_control":"request_decision","decision":"accepted"}'),
        isNull,
      );
    });
  });
}
