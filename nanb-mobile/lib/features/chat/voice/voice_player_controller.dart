import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';

import '../services/temp_media_store.dart';

/// Test seam over the platform audio player. Production wires `_RealSeam`
/// which drives `just_audio`'s `AudioPlayer`; tests inject a fake.
abstract class PlayerSeam {
  Future<void> loadBytes(List<int> bytes);
  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration to);
  Stream<Duration> get position;

  /// Emits once when playback reaches the end of the track. The controller
  /// uses this to flip `isPlaying` back to false and arm a play-from-start
  /// on the next tap.
  Stream<void> get onComplete;
  Future<Duration?> totalDurationOrNull();
  Future<void> dispose();
}

/// Production seam backed by `just_audio`. Excluded from unit-test coverage
/// (third-party plugin glue) per project policy — `_FakePlayer` in the
/// controller's test covers the contract.
class _RealSeam implements PlayerSeam {
  final _player = AudioPlayer();
  File? _tempFile;

  @override
  Future<void> loadBytes(List<int> bytes) async {
    final dir = await getTemporaryDirectory();
    final ts = DateTime.now().microsecondsSinceEpoch;
    // Under the shared TempMediaStore prefix so sweepAll reclaims it if the
    // process is killed mid-playback before dispose() deletes it. Untagged (no
    // envelope) — dispose + sweepAll cover it; per-message delete does not.
    final f = File('${dir.path}/${TempMediaStoreImpl.filePrefix}voiceplay-$ts.m4a');
    await f.writeAsBytes(bytes, flush: true);
    _tempFile = f;
    await _player.setFilePath(f.path);
  }

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> seek(Duration to) => _player.seek(to);

  @override
  Stream<Duration> get position => _player.positionStream;

  @override
  Stream<void> get onComplete => _player.processingStateStream
      .where((s) => s == ProcessingState.completed)
      .map((_) {});

  @override
  Future<Duration?> totalDurationOrNull() async => _player.duration;

  @override
  Future<void> dispose() async {
    await _player.dispose();
    try {
      await _tempFile?.delete();
    } catch (_) {/* best-effort */}
  }
}

/// Drives one voice-note's playback. Held by `MessageBubbleVoice` (one
/// controller per bubble). Listens to position updates and exposes a
/// `progress` 0..1, an `isPlaying` flag, and a `durationLabel` for the UI.
class VoicePlayerController extends ChangeNotifier {
  VoicePlayerController({PlayerSeam? seam}) : _seam = seam ?? _RealSeam();

  final PlayerSeam _seam;
  Duration _position = Duration.zero;
  Duration? _total;
  bool _isPlaying = false;
  bool _endedNaturally = false;
  StreamSubscription<Duration>? _posSub;
  StreamSubscription<void>? _completeSub;

  bool get isPlaying => _isPlaying;

  /// 0..1; returns 0 when total duration is unknown or zero.
  double get progress {
    final t = _total;
    if (t == null || t.inMicroseconds <= 0) return 0;
    final r = _position.inMicroseconds / t.inMicroseconds;
    return r.clamp(0.0, 1.0);
  }

  /// `m:ss` label for the total duration; `0:00` when unknown.
  String get durationLabel => _formatDuration(_total ?? Duration.zero);

  Future<void> load(List<int> bytes) async {
    await _seam.loadBytes(bytes);
    _total = await _seam.totalDurationOrNull();
    _posSub = _seam.position.listen((p) {
      _position = p;
      notifyListeners();
    });
    _completeSub = _seam.onComplete.listen((_) {
      _isPlaying = false;
      _endedNaturally = true;
      _position = _total ?? _position;
      notifyListeners();
    });
    notifyListeners();
  }

  Future<void> toggle() async {
    if (_isPlaying) {
      await _seam.pause();
      _isPlaying = false;
    } else {
      if (_endedNaturally) {
        await _seam.seek(Duration.zero);
        _position = Duration.zero;
        _endedNaturally = false;
      }
      // Do NOT await play(): just_audio's play() future only resolves when
      // playback finishes or is paused, so awaiting it set isPlaying AFTER
      // the audio had already ended — the bubble showed the play icon for
      // the whole playback and a stale pause icon afterwards.
      unawaited(_seam.play());
      _isPlaying = true;
    }
    notifyListeners();
  }

  /// Jump to `fraction` (0..1) of the track — waveform scrubbing. No-op
  /// until the track is loaded (total duration unknown). Seeking while
  /// ended re-arms normal playback from the new position.
  Future<void> seekToFraction(double fraction) async {
    final t = _total;
    if (t == null || t.inMicroseconds <= 0) return;
    final clamped = fraction.clamp(0.0, 1.0);
    final to = Duration(
      microseconds: (t.inMicroseconds * clamped).round(),
    );
    _endedNaturally = false;
    _position = to; // optimistic — the position stream confirms shortly
    await _seam.seek(to);
    notifyListeners();
  }

  @override
  Future<void> dispose() async {
    await _posSub?.cancel();
    await _completeSub?.cancel();
    await _seam.dispose();
    super.dispose();
  }

  static String _formatDuration(Duration d) {
    final mm = d.inMinutes.remainder(60).toString();
    final ss = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$mm:$ss';
  }
}
