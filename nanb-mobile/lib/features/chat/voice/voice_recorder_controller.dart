import 'dart:async';
import 'dart:io';

import 'package:flutter_sound/flutter_sound.dart' as fs;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart' as ph;

/// Test seam over the platform recorder. Production wires `_RealSeam` which
/// drives `flutter_sound`'s `FlutterSoundRecorder`; tests inject a fake to
/// keep recorder controller logic deterministic + free of plugin glue.
abstract class RecorderSeam {
  Future<bool> hasPermission();
  Future<void> start({required String path});

  /// Returns the recorded file's path on success.
  Future<String?> stop();
  Future<void> cancel();
  Future<void> dispose();

  /// Stream of mic-input amplitude readings normalized to 0..1. Emits on the
  /// underlying plugin's progress cadence (~100ms). Broadcast so callers can
  /// rebind without losing prior emissions.
  Stream<double> get amplitudes;
}

/// Production seam backed by `flutter_sound`. Excluded from unit-test coverage
/// (third-party plugin glue) per project policy — `_FakeRecorder` in the
/// controller's test covers the contract.
class _RealSeam implements RecorderSeam {
  final _recorder = fs.FlutterSoundRecorder();
  final _amplitudeCtl = StreamController<double>.broadcast();
  bool _opened = false;
  String? _path;
  StreamSubscription<fs.RecordingDisposition>? _progressSub;

  @override
  Stream<double> get amplitudes => _amplitudeCtl.stream;

  @override
  Future<bool> hasPermission() async {
    // RECORD_AUDIO is a runtime permission on Android 6+ — the manifest
    // entry alone isn't enough, and flutter_sound does NOT request it
    // (startRecorder just fails with a PlatformException on real devices).
    // request() shows the system prompt on first use and is a cheap
    // status read once the user has decided.
    final status = await ph.Permission.microphone.request();
    if (!status.isGranted) return false;
    try {
      if (!_opened) {
        await _recorder.openRecorder();
        _opened = true;
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> start({required String path}) async {
    if (!_opened) {
      await _recorder.openRecorder();
      _opened = true;
    }
    _path = path;
    await _recorder.setSubscriptionDuration(const Duration(milliseconds: 100));
    await _recorder.startRecorder(toFile: path, codec: fs.Codec.aacMP4);
    _progressSub = _recorder.onProgress?.listen((d) {
      // flutter_sound reports decibels in roughly -60..0 range. Map to 0..1
      // by clamping then normalizing.
      final db = d.decibels ?? -60.0;
      final clamped = db.clamp(-60.0, 0.0);
      final normalized = (clamped + 60.0) / 60.0;
      _amplitudeCtl.add(normalized);
    });
  }

  @override
  Future<String?> stop() async {
    await _progressSub?.cancel();
    _progressSub = null;
    await _recorder.stopRecorder();
    final p = _path;
    _path = null;
    if (p != null) await _awaitFinalized(p);
    return p;
  }

  /// flutter_sound's stopRecorder can resolve before the native
  /// MediaRecorder has flushed its last encoder buffers and written the MP4
  /// moov index. The caller reads the file the moment stop() returns (and
  /// popping the sheet disposes the recorder, which can abort an in-flight
  /// finalization) — without this wait the recording loses its last
  /// 1-2 seconds. Poll until the size is stable AND a moov atom exists,
  /// bounded so a misbehaving encoder can't hang the send.
  static Future<void> _awaitFinalized(String path) async {
    final f = File(path);
    var lastLen = -1;
    for (var i = 0; i < 40; i++) {
      // ≤ ~2s total
      try {
        final len = await f.length();
        if (len > 0 && len == lastLen && await _hasMoovTail(f, len)) return;
        lastLen = len;
      } catch (_) {/* file not visible yet */}
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  /// MediaRecorder writes the moov atom at finalize time, after the mdat
  /// payload — scan the trailing 64 KiB for the tag.
  static Future<bool> _hasMoovTail(File f, int len) async {
    final start = len > 65536 ? len - 65536 : 0;
    final raf = await f.open();
    try {
      await raf.setPosition(start);
      final bytes = await raf.read(len - start);
      for (var i = 0; i + 4 <= bytes.length; i++) {
        if (bytes[i] == 0x6D /* m */ &&
            bytes[i + 1] == 0x6F /* o */ &&
            bytes[i + 2] == 0x6F /* o */ &&
            bytes[i + 3] == 0x76 /* v */) {
          return true;
        }
      }
      return false;
    } finally {
      await raf.close();
    }
  }

  @override
  Future<void> cancel() async {
    await _progressSub?.cancel();
    _progressSub = null;
    try {
      await _recorder.stopRecorder();
    } catch (_) {/* not active */}
    final p = _path;
    _path = null;
    // The discarded take is plaintext audio in the temp dir — don't leave
    // it behind (stop may not have finalized it; delete is best-effort).
    if (p != null) {
      try {
        await File(p).delete();
      } catch (_) {/* never created / still held */}
    }
  }

  @override
  Future<void> dispose() async {
    await _progressSub?.cancel();
    _progressSub = null;
    await _amplitudeCtl.close();
    if (_opened) {
      try {
        await _recorder.closeRecorder();
      } catch (_) {/* already closed */}
      _opened = false;
    }
  }
}

/// Outcome of a successful voice recording. Bundles the file path with the
/// captured amplitude samples (resampled to [VoiceRecorderController.waveformBars]
/// bars) so the caller can ship both over the wire.
class VoiceRecordingResult {
  const VoiceRecordingResult({
    required this.path,
    required this.waveform,
    this.duration = Duration.zero,
  });

  final String path;

  /// Normalized amplitude samples (0..255). Length is bounded by
  /// [VoiceRecorderController.waveformBars]. Empty if no amplitude data
  /// was emitted (very short recordings or stub seams).
  final List<int> waveform;

  /// Wall-clock recording length (including the tail grace). Ships in the
  /// media descriptor so bubbles can show the real duration before the
  /// audio is ever downloaded.
  final Duration duration;
}

/// Drives recorder state for a single voice-note session. Owns the seam +
/// the elapsed-time ticker the recorder-sheet UI binds to.
class VoiceRecorderController {
  VoiceRecorderController({
    RecorderSeam? seam,
    Future<String> Function()? tempPathBuilder,
    Duration tick = const Duration(milliseconds: 100),
    Duration tailGrace = Duration.zero,
  })  : _seam = seam ?? _RealSeam(),
        _tempPathBuilder = tempPathBuilder ?? _defaultTempPath,
        _tick = tick,
        _tailGrace = tailGrace;

  final RecorderSeam _seam;
  final Future<String> Function() _tempPathBuilder;
  final Duration _tick;

  /// Keeps recording for this long after stop() is requested. Users tap
  /// Send the instant they finish talking — without a grace window the
  /// trailing word is still in the encoder pipeline and gets clipped.
  final Duration _tailGrace;
  final _elapsedCtl = StreamController<Duration>.broadcast();
  Timer? _timer;
  DateTime? _startedAt;
  bool _active = false;
  final List<double> _ampSamples = [];
  StreamSubscription<double>? _ampSub;

  /// Number of bars the rendered waveform contains. Captured amplitudes are
  /// resampled (averaged into buckets) down to this size before transmit so
  /// the wire payload stays tiny (~64 bytes).
  static const int waveformBars = 64;

  /// Emits the elapsed recording duration at the configured `tick` cadence.
  /// Broadcast so the sheet UI can rebind on rebuild without losing events.
  Stream<Duration> get elapsed => _elapsedCtl.stream;

  /// Begin a voice recording. Throws [StateError] if microphone permission
  /// is denied. Idempotent — calling while a recording is active is a no-op.
  Future<void> start() async {
    if (_active) return;
    final granted = await _seam.hasPermission();
    if (!granted) {
      throw StateError('Microphone permission denied.');
    }
    final path = await _tempPathBuilder();
    _ampSamples.clear();
    _ampSub = _seam.amplitudes.listen(_ampSamples.add);
    await _seam.start(path: path);
    _startedAt = DateTime.now();
    _active = true;
    _timer = Timer.periodic(_tick, (_) {
      final s = _startedAt;
      if (s == null) return;
      _elapsedCtl.add(DateTime.now().difference(s));
    });
  }

  /// Finish the recording. Returns the recorded file's path + captured
  /// waveform, or null if no recording was active.
  Future<VoiceRecordingResult?> stop() async {
    if (!_active) return null;
    if (_tailGrace > Duration.zero) {
      await Future<void>.delayed(_tailGrace);
    }
    _timer?.cancel();
    _timer = null;
    _active = false;
    final startedAt = _startedAt;
    _startedAt = null;
    await _ampSub?.cancel();
    _ampSub = null;
    final path = await _seam.stop();
    if (path == null) return null;
    return VoiceRecordingResult(
      path: path,
      waveform: _resampleAmplitudes(_ampSamples),
      duration: startedAt == null
          ? Duration.zero
          : DateTime.now().difference(startedAt),
    );
  }

  /// Discard the recording. No-op if no recording was active.
  Future<void> cancel() async {
    if (!_active) return;
    _timer?.cancel();
    _timer = null;
    _active = false;
    _startedAt = null;
    await _ampSub?.cancel();
    _ampSub = null;
    _ampSamples.clear();
    await _seam.cancel();
  }

  /// Release native resources + close the elapsed stream. The controller is
  /// not reusable after dispose. If a recording is still active (e.g. the
  /// sheet was popped via system back instead of Send/Cancel), cancel it
  /// first so the recorder's underlying file isn't left half-written.
  Future<void> dispose() async {
    if (_active) {
      await cancel();
    }
    _timer?.cancel();
    await _ampSub?.cancel();
    _ampSub = null;
    await _elapsedCtl.close();
    await _seam.dispose();
  }

  /// Bucket-averages [samples] (normalized 0..1) down to [waveformBars] bars
  /// and scales each to a 0..255 byte. Public for testing.
  static List<int> resampleAmplitudes(List<double> samples) =>
      _resampleAmplitudes(samples);

  static List<int> _resampleAmplitudes(List<double> samples) {
    if (samples.isEmpty) return const [];
    if (samples.length <= waveformBars) {
      // Already small enough — just scale to byte range.
      return samples
          .map((v) => (v.clamp(0.0, 1.0) * 255).round())
          .toList(growable: false);
    }
    final out = List<int>.filled(waveformBars, 0);
    final bucketSize = samples.length / waveformBars;
    for (var i = 0; i < waveformBars; i++) {
      final lo = (i * bucketSize).floor();
      final hi = ((i + 1) * bucketSize).floor().clamp(lo + 1, samples.length);
      var sum = 0.0;
      for (var j = lo; j < hi; j++) {
        sum += samples[j];
      }
      final avg = sum / (hi - lo);
      out[i] = (avg.clamp(0.0, 1.0) * 255).round();
    }
    return out;
  }
}

Future<String> _defaultTempPath() async {
  final dir = await getTemporaryDirectory();
  final ts = DateTime.now().microsecondsSinceEpoch;
  return '${dir.path}/nanb-voice-$ts.m4a';
}
