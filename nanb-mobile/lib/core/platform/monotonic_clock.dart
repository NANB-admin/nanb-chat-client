import 'package:flutter/services.dart';

/// Boot-relative MONOTONIC time — milliseconds since device boot, unaffected by
/// wall-clock (`DateTime.now`) changes. Used to make the passcode brute-force
/// lockout resistant to a "roll the clock forward to skip the wait" bypass.
///
/// Backed by a tiny native channel: Android `SystemClock.elapsedRealtime()`
/// (counts time in deep sleep), iOS `ProcessInfo.systemUptime`. It RESETS on
/// reboot and is NOT wall-clock — callers must treat a value going backwards as
/// a reboot and fall back to a wall-clock deadline.
///
/// [elapsedRealtimeMs] returns null when the platform can't provide it (channel
/// missing / error) so callers degrade to wall-clock behavior rather than break.
class MonotonicClock {
  static const MethodChannel _channel =
      MethodChannel('nanb.app/monotonic_clock');

  static Future<int?> elapsedRealtimeMs() async {
    try {
      final v = await _channel.invokeMethod('elapsedRealtimeMs');
      // Android returns a Long (ms-since-boot overflows int32 after ~25 days of
      // uptime), so accept any num and widen to Dart's 64-bit int.
      return (v as num?)?.toInt();
    } catch (_) {
      return null; // unsupported / not wired → caller falls back to wall-clock
    }
  }
}
