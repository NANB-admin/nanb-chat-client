import 'package:flutter/services.dart';

/// Keeps the app process alive in the background for the live span of a call, so
/// an audio call (or a minimized video call) isn't suspended when the user locks
/// the screen or switches apps — which would stop WebRTC media and, once the
/// peer's recovery windows expire, drop the call.
///
/// On **Android** this drives a `microphone` foreground service + a partial
/// wake lock (see `CallForegroundService.kt`), started/stopped by the same
/// live-call edge that drives [CallWindow].
///
/// Off Android the channel isn't registered, so this is a best-effort no-op:
/// **iOS** keeps the app alive for a live call via the `audio` `UIBackgroundModes`
/// entry plus WebRTC's active `AVAudioSession`, with no explicit service.
class CallForegroundService {
  CallForegroundService._();

  static const MethodChannel _channel =
      MethodChannel('nanb.app/call_foreground');

  /// True while we believe the service is running, so we skip redundant channel
  /// hops on every status tick.
  static bool _running = false;

  /// A call became live — keep the process alive in the background.
  static Future<void> start() async {
    if (_running) return;
    _running = true;
    try {
      // Native returns false when it couldn't actually start — notably on the
      // first-ever call, where RECORD_AUDIO is granted a beat AFTER this ring
      // edge. Un-latch so the next status edge (connecting/active, mic now
      // granted) retries. iOS has no channel → MissingPluginException → stays
      // latched (it uses the `audio` background mode, no service to start).
      final started = await _channel.invokeMethod<bool>('start');
      if (started == false) _running = false;
    } on MissingPluginException {
      // Not Android (tests / iOS) — iOS uses the `audio` background mode instead.
    } on PlatformException {
      _running = false; // let the next status change retry
    }
  }

  /// The call ended — let the process be backgrounded/suspended normally.
  static Future<void> stop() async {
    if (!_running) return;
    _running = false;
    try {
      await _channel.invokeMethod<void>('stop');
    } on MissingPluginException {
      // Not Android (tests / iOS) — nothing to stop.
    } on PlatformException {
      // Best-effort; the service also self-caps its wake lock as a backstop.
    }
  }
}
