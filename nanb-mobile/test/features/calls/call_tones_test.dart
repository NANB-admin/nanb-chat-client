import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:mocktail/mocktail.dart';
import 'package:nanb_chat/features/calls/call_tones.dart';

class _MockPlayer extends Mock implements AudioPlayer {}

String _ascii(Uint8List b, int start, int len) =>
    String.fromCharCodes(b.sublist(start, start + len));

int _u32le(Uint8List b, int o) =>
    b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24);

void main() {
  test('wavFromPcm16 writes a valid PCM16 mono header', () {
    final wav = wavFromPcm16(Int16List.fromList([0, 1, -1, 32767]), 16000);
    expect(_ascii(wav, 0, 4), 'RIFF');
    expect(_ascii(wav, 8, 4), 'WAVE');
    expect(_ascii(wav, 12, 4), 'fmt ');
    expect(_ascii(wav, 36, 4), 'data');
    expect(_u32le(wav, 40), 4 * 2, reason: '4 samples * 2 bytes');
    expect(wav.length, 44 + 4 * 2);
    // mono, 16-bit, 16 kHz
    expect(wav[22], 1); // num channels
    expect(_u32le(wav, 24), 16000); // sample rate
    expect(wav[34], 16); // bits per sample
  });

  test('ringback cadence is 2s tone + 4s silence @ 16kHz mono', () {
    final wav = ringbackToneWav();
    const expectedData = (2 + 4) * 16000 * 2;
    expect(wav.length, 44 + expectedData);
    expect(_u32le(wav, 40), expectedData);
    // The tail (silence) is all zero samples.
    expect(wav.sublist(wav.length - 100).every((b) => b == 0), isTrue);
    // The tone region (early samples) is NOT all zero.
    expect(wav.sublist(44, 44 + 2000).any((b) => b != 0), isTrue);
  });

  test('ringtone cadence is shorter (1s + 1s)', () {
    final wav = ringtoneWav();
    expect(wav.length, 44 + (1 + 1) * 16000 * 2);
  });

  test('stop() always stops the player (even when nothing is tracked playing)',
      () async {
    // Regression: stop() used to early-return when `_playing == null`. A lost
    // start/stop race can leave the player looping while `_playing` is already
    // null — then that early return meant the ring tone played forever (until
    // the app was killed). stop() must unconditionally stop the player.
    final player = _MockPlayer();
    when(() => player.stop()).thenAnswer((_) async {});

    final tones = CallTones(player: player);
    await tones.stop();

    verify(() => player.stop()).called(1);
  });
}
