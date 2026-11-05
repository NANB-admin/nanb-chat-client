import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/features/chat/voice/voice_recorder_controller.dart';

class _FakeRecorder implements RecorderSeam {
  String? lastPath;
  bool isRecording = false;
  bool hasPermissionResult = true;
  bool disposed = false;

  final _ampCtl = StreamController<double>.broadcast();

  @override
  Stream<double> get amplitudes => _ampCtl.stream;

  @override
  Future<bool> hasPermission() async => hasPermissionResult;

  @override
  Future<void> start({required String path}) async {
    lastPath = path;
    isRecording = true;
  }

  @override
  Future<String?> stop() async {
    isRecording = false;
    return lastPath;
  }

  @override
  Future<void> cancel() async {
    isRecording = false;
    lastPath = null;
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    await _ampCtl.close();
  }

  /// Test helper — feeds an amplitude sample to the controller as if the
  /// underlying plugin emitted it.
  void emitAmplitude(double v) => _ampCtl.add(v);
}

void main() {
  group('VoiceRecorderController', () {
    test('start() throws StateError when permission denied', () async {
      final fake = _FakeRecorder()..hasPermissionResult = false;
      final c = VoiceRecorderController(
        seam: fake,
        tempPathBuilder: () async => '/tmp/voice.m4a',
      );
      await expectLater(c.start(), throwsA(isA<StateError>()));
      expect(fake.isRecording, isFalse);
      expect(fake.lastPath, isNull);
    });

    test('start() initiates recording at the temp path', () async {
      final fake = _FakeRecorder();
      final c = VoiceRecorderController(
        seam: fake,
        tempPathBuilder: () async => '/tmp/voice.m4a',
      );
      await c.start();
      expect(fake.isRecording, isTrue);
      expect(fake.lastPath, '/tmp/voice.m4a');
    });

    test('start() is idempotent — second call does not re-open', () async {
      final fake = _FakeRecorder();
      var paths = 0;
      final c = VoiceRecorderController(
        seam: fake,
        tempPathBuilder: () async {
          paths++;
          return '/tmp/voice-$paths.m4a';
        },
      );
      await c.start();
      await c.start();
      expect(paths, 1);
      expect(fake.lastPath, '/tmp/voice-1.m4a');
    });

    test('stop() keeps recording for the tailGrace window before stopping',
        () async {
      final fake = _FakeRecorder();
      final c = VoiceRecorderController(
        seam: fake,
        tempPathBuilder: () async => '/tmp/voice.m4a',
        tailGrace: const Duration(milliseconds: 120),
      );
      await c.start();

      final sw = Stopwatch()..start();
      final stopping = c.stop();
      // Immediately after requesting stop, the seam must still be recording —
      // the grace window captures the word the user finishes as they tap.
      expect(fake.isRecording, isTrue);
      await stopping;
      sw.stop();

      expect(fake.isRecording, isFalse);
      expect(sw.elapsedMilliseconds, greaterThanOrEqualTo(100));
    });

    test('stop() returns a VoiceRecordingResult with the recorded path',
        () async {
      final fake = _FakeRecorder();
      final c = VoiceRecorderController(
        seam: fake,
        tempPathBuilder: () async => '/tmp/v.m4a',
      );
      await c.start();
      final result = await c.stop();
      expect(result, isNotNull);
      expect(result!.path, '/tmp/v.m4a');
      expect(fake.isRecording, isFalse);
    });

    test('stop() before start returns null', () async {
      final fake = _FakeRecorder();
      final c = VoiceRecorderController(
        seam: fake,
        tempPathBuilder: () async => '/tmp/v.m4a',
      );
      expect(await c.stop(), isNull);
    });

    test('stop() returns the captured amplitudes as waveform', () async {
      final fake = _FakeRecorder();
      final c = VoiceRecorderController(
        seam: fake,
        tempPathBuilder: () async => '/tmp/v.m4a',
      );
      await c.start();
      fake.emitAmplitude(0.0);
      fake.emitAmplitude(0.5);
      fake.emitAmplitude(1.0);
      await Future<void>.delayed(Duration.zero);
      final result = await c.stop();
      expect(result, isNotNull);
      expect(result!.waveform, [0, 128, 255]);
    });

    test('stop() returns an empty waveform when no amplitudes were captured',
        () async {
      final fake = _FakeRecorder();
      final c = VoiceRecorderController(
        seam: fake,
        tempPathBuilder: () async => '/tmp/v.m4a',
      );
      await c.start();
      final result = await c.stop();
      expect(result, isNotNull);
      expect(result!.waveform, isEmpty);
    });

    test('cancel() drops the recording', () async {
      final fake = _FakeRecorder();
      final c = VoiceRecorderController(
        seam: fake,
        tempPathBuilder: () async => '/tmp/v.m4a',
      );
      await c.start();
      await c.cancel();
      expect(fake.lastPath, isNull);
      expect(fake.isRecording, isFalse);
    });

    test('cancel() before start is a no-op', () async {
      final fake = _FakeRecorder();
      final c = VoiceRecorderController(
        seam: fake,
        tempPathBuilder: () async => '/tmp/v.m4a',
      );
      await c.cancel();
      expect(fake.isRecording, isFalse);
      expect(fake.lastPath, isNull);
    });

    test('cancel() discards previously-captured amplitudes', () async {
      final fake = _FakeRecorder();
      final c = VoiceRecorderController(
        seam: fake,
        tempPathBuilder: () async => '/tmp/v.m4a',
      );
      await c.start();
      fake.emitAmplitude(0.5);
      await Future<void>.delayed(Duration.zero);
      await c.cancel();
      // After cancel, a fresh recording should not see prior samples.
      await c.start();
      final result = await c.stop();
      expect(result!.waveform, isEmpty);
    });

    test('elapsed stream emits monotonically increasing durations', () async {
      final fake = _FakeRecorder();
      final c = VoiceRecorderController(
        seam: fake,
        tempPathBuilder: () async => '/tmp/v.m4a',
        tick: const Duration(milliseconds: 10),
      );
      final seen = <Duration>[];
      final sub = c.elapsed.listen(seen.add);
      await c.start();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      await c.stop();
      await sub.cancel();
      expect(seen.length, greaterThanOrEqualTo(3));
      for (var i = 1; i < seen.length; i++) {
        expect(seen[i] >= seen[i - 1], isTrue);
      }
    });

    test('dispose closes the elapsed stream + disposes the seam', () async {
      final fake = _FakeRecorder();
      final c = VoiceRecorderController(
        seam: fake,
        tempPathBuilder: () async => '/tmp/v.m4a',
      );
      var streamDone = false;
      c.elapsed.listen((_) {}, onDone: () => streamDone = true);
      await c.dispose();
      // Yield one microtask so the controller's close() observers settle.
      await Future<void>.delayed(Duration.zero);
      expect(streamDone, isTrue);
      expect(fake.disposed, isTrue);
    });

    test('dispose while a recording is active cancels it first', () async {
      final fake = _FakeRecorder();
      final c = VoiceRecorderController(
        seam: fake,
        tempPathBuilder: () async => '/tmp/v.m4a',
      );
      await c.start();
      expect(fake.isRecording, isTrue);
      await c.dispose();
      expect(fake.isRecording, isFalse,
          reason: 'dispose should cancel the active recording before closing');
      expect(fake.lastPath, isNull);
      expect(fake.disposed, isTrue);
    });
  });

  group('VoiceRecorderController.resampleAmplitudes', () {
    test('returns empty list for no samples', () {
      expect(VoiceRecorderController.resampleAmplitudes(const []), isEmpty);
    });

    test('scales sub-bar count to bytes without resampling', () {
      final out = VoiceRecorderController.resampleAmplitudes(const [0.0, 0.5, 1.0]);
      expect(out, [0, 128, 255]);
    });

    test('caps output length at waveformBars when input is larger', () {
      final input = List<double>.generate(500, (i) => 1.0);
      final out = VoiceRecorderController.resampleAmplitudes(input);
      expect(out.length, VoiceRecorderController.waveformBars);
    });

    test('bucket-averages downsampled amplitudes', () {
      // Input of length 128 collapses to 64 bars, each the average of 2
      // adjacent samples.
      final input = List<double>.generate(128, (i) => i.isEven ? 0.0 : 1.0);
      final out = VoiceRecorderController.resampleAmplitudes(input);
      expect(out.length, 64);
      // Every bar averages one 0.0 and one 1.0 → 0.5 → 128
      expect(out.every((b) => b == 128), isTrue);
    });

    test('clamps amplitudes outside 0..1 into byte range', () {
      final out = VoiceRecorderController.resampleAmplitudes(const [-0.5, 1.5]);
      expect(out, [0, 255]);
    });
  });
}
