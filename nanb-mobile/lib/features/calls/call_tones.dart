import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';

/// Builds a minimal PCM16 mono WAV (44-byte header + samples) at [sampleRate].
/// Pure + testable.
Uint8List wavFromPcm16(Int16List samples, int sampleRate) {
  final data = samples.buffer.asUint8List(samples.offsetInBytes, samples.lengthInBytes);
  final out = BytesBuilder();
  void str(String s) => out.add(s.codeUnits);
  void u32(int v) => out.add([v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff]);
  void u16(int v) => out.add([v & 0xff, (v >> 8) & 0xff]);
  str('RIFF');
  u32(36 + data.length);
  str('WAVE');
  str('fmt ');
  u32(16); // PCM fmt chunk size
  u16(1); // PCM
  u16(1); // mono
  u32(sampleRate);
  u32(sampleRate * 2); // byte rate (mono, 16-bit)
  u16(2); // block align
  u16(16); // bits per sample
  str('data');
  u32(data.length);
  out.add(data);
  return out.toBytes();
}

/// One cadence cycle of a dual-tone "phone ring" (440 + 480 Hz — the classic
/// North-American ringback pair): [onSeconds] of tone then [offSeconds] of
/// silence, looped by the player. Short fades avoid loop-boundary clicks.
Uint8List ringCadenceWav({
  required double onSeconds,
  required double offSeconds,
  int sampleRate = 16000,
}) {
  final onN = (onSeconds * sampleRate).round();
  final offN = (offSeconds * sampleRate).round();
  final samples = Int16List(onN + offN);
  final fadeN = (0.01 * sampleRate).round(); // 10 ms ramp
  for (var i = 0; i < onN; i++) {
    final t = i / sampleRate;
    var v = 0.28 * 0.5 * (sin(2 * pi * 440 * t) + sin(2 * pi * 480 * t));
    if (i < fadeN) v *= i / fadeN;
    if (i > onN - fadeN) v *= (onN - i) / fadeN;
    samples[i] = (v * 32767).round();
  }
  // remaining (offN) stays zero = silence
  return wavFromPcm16(samples, sampleRate);
}

/// The caller's ringback ("ring… ring…" while the other side rings).
Uint8List ringbackToneWav() => ringCadenceWav(onSeconds: 2.0, offSeconds: 4.0);

/// The callee's incoming ringtone (faster cadence) — used when an inbound call
/// arrives while the app is foregrounded.
Uint8List ringtoneWav() => ringCadenceWav(onSeconds: 1.0, offSeconds: 1.0);

/// Plays the call ring tones via `just_audio`, looping. Best-effort: a failure
/// to play just means no tone (never breaks the call). Not unit-tested (plugin
/// glue, like the voice player's real seam) — the WAV generators above are.
class CallTones {
  CallTones({AudioPlayer? player}) : _player = player ?? AudioPlayer();

  final AudioPlayer _player;
  File? _temp;
  String? _playing;
  StreamSubscription<ProcessingState>? _stateSub;

  /// Bumped on every start/stop. An in-flight [_loop] captures this and bails at
  /// each async step once a newer start/stop supersedes it. Without this a
  /// stop() that lands while _loop is still setting up (temp-file write,
  /// setFilePath) gets overtaken by the trailing _player.play(), which starts a
  /// LoopMode.one loop AFTER the stop — a tone that then plays forever because
  /// stop() (gated on _playing, now null) never runs again. That was the "ring
  /// tone keeps going after the call connects/ends until you kill the app" bug.
  int _generation = 0;

  Future<void> startRingback() => _loop('ringback', ringbackToneWav());
  Future<void> startRingtone() => _loop('ringtone', ringtoneWav());

  Future<void> _loop(String kind, Uint8List wav) async {
    if (_playing == kind) return;
    final gen = ++_generation;
    _playing = kind;
    try {
      final dir = await getTemporaryDirectory();
      if (gen != _generation) return; // superseded by a stop()/new tone
      final f = File('${dir.path}/nanb-$kind.wav');
      await f.writeAsBytes(wav, flush: true);
      if (gen != _generation) return;
      _temp = f;
      await _player.setFilePath(f.path);
      if (gen != _generation) return;
      await _player.setVolume(0.6);
      // Loop the cadence until stop(). LoopMode.one alone proved unreliable for
      // a single setFilePath source on Android (the ring played once and went
      // silent), so we ALSO replay manually on completion — whichever engages,
      // the ring keeps going for the whole outgoing-ringing wait.
      await _player.setLoopMode(LoopMode.one);
      if (gen != _generation) return;
      await _stateSub?.cancel();
      _stateSub = _player.processingStateStream.listen((state) {
        if (state == ProcessingState.completed && gen == _generation) {
          _player.seek(Duration.zero);
          _player.play();
        }
      });
      // Final guard: no await between here and play(), so a concurrent stop()
      // either already flipped _generation (caught above) or lands after play
      // starts (and its _player.stop() then wins).
      if (gen != _generation) return;
      await _player.play();
    } catch (_) {/* best-effort; no tone is not fatal */}
  }

  Future<void> stop() async {
    // Supersede any in-flight _loop and ALWAYS stop the player — do NOT gate on
    // _playing. A lost start/stop race can leave the player looping while
    // _playing is already null; a _playing-gated early return would then never
    // stop it (the tone plays until the app is killed).
    _generation++;
    _playing = null;
    try {
      await _stateSub?.cancel();
      _stateSub = null;
      await _player.stop();
    } catch (_) {/* best-effort */}
  }

  Future<void> dispose() async {
    try {
      await _stateSub?.cancel();
    } catch (_) {}
    try {
      await _player.dispose();
    } catch (_) {}
    try {
      await _temp?.delete();
    } catch (_) {}
  }
}
