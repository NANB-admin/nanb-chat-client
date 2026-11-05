import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/features/chat/voice/voice_player_controller.dart';

class _FakePlayer implements PlayerSeam {
  bool isPlaying = false;
  Duration totalDuration = const Duration(seconds: 10);

  /// When true, play() returns a future that never resolves — mirrors
  /// just_audio, whose play() only completes when playback finishes or is
  /// paused. The controller must not await it.
  bool playNeverResolves = false;
  final _positionCtl = StreamController<Duration>.broadcast();
  final _completeCtl = StreamController<void>.broadcast();
  bool loaded = false;
  List<int>? loadedBytes;
  bool disposed = false;
  Duration lastSeek = Duration.zero;
  int seekCalls = 0;

  @override
  Future<void> loadBytes(List<int> bytes) async {
    loaded = true;
    loadedBytes = bytes;
  }

  @override
  Future<void> play() {
    isPlaying = true;
    if (playNeverResolves) return Completer<void>().future;
    return Future<void>.value();
  }

  @override
  Future<void> pause() async {
    isPlaying = false;
  }

  @override
  Future<void> seek(Duration to) async {
    lastSeek = to;
    seekCalls++;
    _positionCtl.add(to);
  }

  @override
  Stream<Duration> get position => _positionCtl.stream;

  @override
  Stream<void> get onComplete => _completeCtl.stream;

  @override
  Future<Duration?> totalDurationOrNull() async => totalDuration;

  @override
  Future<void> dispose() async {
    disposed = true;
    await _positionCtl.close();
    await _completeCtl.close();
  }

  void emitPosition(Duration d) => _positionCtl.add(d);
  void emitComplete() => _completeCtl.add(null);
}

void main() {
  group('VoicePlayerController', () {
    test('progress is 0 before any position events', () {
      final c = VoicePlayerController(seam: _FakePlayer());
      expect(c.progress, 0.0);
    });

    test('toggle() plays after load + first call; pauses after second', () async {
      final fake = _FakePlayer();
      final c = VoicePlayerController(seam: fake);
      await c.load(const [1, 2, 3]);
      await c.toggle();
      expect(fake.isPlaying, isTrue);
      expect(c.isPlaying, isTrue);
      await c.toggle();
      expect(fake.isPlaying, isFalse);
      expect(c.isPlaying, isFalse);
    });

    test('toggle() flips isPlaying immediately even when play() never resolves',
        () async {
      // just_audio's play() future resolves only when playback ENDS —
      // awaiting it meant isPlaying flipped after the audio finished (the
      // bubble showed a play icon during playback and a stale pause icon
      // afterwards).
      final fake = _FakePlayer()..playNeverResolves = true;
      final c = VoicePlayerController(seam: fake);
      await c.load(const [1, 2, 3]);

      await c.toggle().timeout(const Duration(seconds: 1));

      expect(fake.isPlaying, isTrue);
      expect(c.isPlaying, isTrue, reason: 'must not wait for play() to end');
    });

    test('seekToFraction seeks proportionally into the track', () async {
      final fake = _FakePlayer()..totalDuration = const Duration(seconds: 10);
      final c = VoicePlayerController(seam: fake);
      await c.load(const [1, 2, 3]);

      await c.seekToFraction(0.5);

      expect(fake.lastSeek, const Duration(seconds: 5));
      expect(c.progress, closeTo(0.5, 0.001));
    });

    test('seekToFraction clamps out-of-range fractions', () async {
      final fake = _FakePlayer()..totalDuration = const Duration(seconds: 10);
      final c = VoicePlayerController(seam: fake);
      await c.load(const [1, 2, 3]);

      await c.seekToFraction(1.7);
      expect(fake.lastSeek, const Duration(seconds: 10));

      await c.seekToFraction(-0.3);
      expect(fake.lastSeek, Duration.zero);
    });

    test('seekToFraction is a no-op before load (unknown duration)', () async {
      final fake = _FakePlayer();
      final c = VoicePlayerController(seam: fake);

      await c.seekToFraction(0.5);

      expect(fake.seekCalls, 0);
    });

    test('seekToFraction after natural end re-arms playback position',
        () async {
      final fake = _FakePlayer()..totalDuration = const Duration(seconds: 10);
      final c = VoicePlayerController(seam: fake);
      await c.load(const [1, 2, 3]);
      await c.toggle();
      fake.emitComplete();
      await Future<void>.delayed(Duration.zero);
      expect(c.isPlaying, isFalse);

      await c.seekToFraction(0.25);
      await c.toggle();

      // Must NOT have re-seeked to zero (the endedNaturally rewind) —
      // playback resumes from the scrubbed position.
      expect(fake.lastSeek, const Duration(milliseconds: 2500));
      expect(c.isPlaying, isTrue);
    });

    test('progress reflects position / totalDuration', () async {
      final fake = _FakePlayer()..totalDuration = const Duration(seconds: 10);
      final c = VoicePlayerController(seam: fake);
      await c.load(const [0]);
      fake.emitPosition(const Duration(seconds: 5));
      await Future<void>.delayed(Duration.zero);
      expect(c.progress, closeTo(0.5, 0.01));
    });

    test('progress clamps to 1.0 when position exceeds totalDuration', () async {
      final fake = _FakePlayer()..totalDuration = const Duration(seconds: 4);
      final c = VoicePlayerController(seam: fake);
      await c.load(const [0]);
      fake.emitPosition(const Duration(seconds: 9));
      await Future<void>.delayed(Duration.zero);
      expect(c.progress, 1.0);
    });

    test('progress is 0 when totalDuration is null', () async {
      final fake = _FakePlayerNullDuration();
      final c = VoicePlayerController(seam: fake);
      await c.load(const [0]);
      fake.emitPosition(const Duration(seconds: 3));
      await Future<void>.delayed(Duration.zero);
      expect(c.progress, 0.0);
    });

    test('durationLabel formats as m:ss', () async {
      final fake = _FakePlayer()..totalDuration = const Duration(seconds: 75);
      final c = VoicePlayerController(seam: fake);
      await c.load(const [0]);
      expect(c.durationLabel, '1:15');
    });

    test('durationLabel is 0:00 when total duration unknown', () {
      final c = VoicePlayerController(seam: _FakePlayerNullDuration());
      expect(c.durationLabel, '0:00');
    });

    test('load forwards bytes to the seam', () async {
      final fake = _FakePlayer();
      final c = VoicePlayerController(seam: fake);
      await c.load(const [7, 7, 7]);
      expect(fake.loaded, isTrue);
      expect(fake.loadedBytes, const [7, 7, 7]);
    });

    test('dispose releases the seam', () async {
      final fake = _FakePlayer();
      final c = VoicePlayerController(seam: fake);
      await c.load(const [0]);
      await c.dispose();
      expect(fake.disposed, isTrue);
    });

    test('onComplete flips isPlaying to false', () async {
      final fake = _FakePlayer();
      final c = VoicePlayerController(seam: fake);
      await c.load(const [0]);
      await c.toggle();
      expect(c.isPlaying, isTrue);
      fake.emitComplete();
      await Future<void>.delayed(Duration.zero);
      expect(c.isPlaying, isFalse);
    });

    test('play after natural end seeks back to zero first', () async {
      final fake = _FakePlayer()..totalDuration = const Duration(seconds: 5);
      final c = VoicePlayerController(seam: fake);
      await c.load(const [0]);
      await c.toggle(); // play
      fake.emitComplete();
      await Future<void>.delayed(Duration.zero);
      final seeksBefore = fake.seekCalls;
      await c.toggle(); // play again
      expect(fake.seekCalls, seeksBefore + 1);
      expect(fake.lastSeek, Duration.zero);
      expect(c.isPlaying, isTrue);
    });

    test('pause then resume does not seek to zero', () async {
      final fake = _FakePlayer();
      final c = VoicePlayerController(seam: fake);
      await c.load(const [0]);
      await c.toggle(); // play
      await c.toggle(); // pause
      final seeksBefore = fake.seekCalls;
      await c.toggle(); // resume
      expect(fake.seekCalls, seeksBefore,
          reason: 'manual pause→resume should not rewind');
    });
  });
}

class _FakePlayerNullDuration implements PlayerSeam {
  final _positionCtl = StreamController<Duration>.broadcast();
  final _completeCtl = StreamController<void>.broadcast();

  @override
  Future<void> loadBytes(List<int> bytes) async {}

  @override
  Future<void> play() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> seek(Duration to) async {}

  @override
  Stream<Duration> get position => _positionCtl.stream;

  @override
  Stream<void> get onComplete => _completeCtl.stream;

  @override
  Future<Duration?> totalDurationOrNull() async => null;

  @override
  Future<void> dispose() async {
    await _positionCtl.close();
    await _completeCtl.close();
  }

  void emitPosition(Duration d) => _positionCtl.add(d);
}
