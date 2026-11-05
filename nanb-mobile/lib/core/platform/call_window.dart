import 'package:flutter/services.dart';

/// Keeps the screen awake and shows the call UI **over the lock screen** while a
/// call is live, by toggling window flags on the Android activity
/// (`FLAG_KEEP_SCREEN_ON` + `FLAG_SHOW_WHEN_LOCKED` + `FLAG_TURN_SCREEN_ON`).
///
/// The native FCM wake (MainActivity's flag-file path) lights the screen for the
/// FIRST frame of an incoming call before Flutter is running; this channel keeps
/// it engaged for the whole ring/connect/active span — driven by [CallOverlay]
/// from the [CallController] status — and releases it the moment the call ends so
/// the device can sleep and relock normally.
///
/// Best-effort no-op off Android (tests / iOS shim) — the channel isn't
/// registered there.
class CallWindow {
  CallWindow._();

  static const MethodChannel _channel = MethodChannel('nanb.app/call_window');

  /// True while we believe the call window flags are engaged, so we skip
  /// redundant channel hops on every status tick.
  static bool _engaged = false;

  /// A call became live — keep the screen on and show over the keyguard.
  static Future<void> engage() => _set(true);

  /// The call ended — let the screen sleep / relock normally.
  static Future<void> release() => _set(false);

  static Future<void> _set(bool engage) async {
    if (engage == _engaged) return;
    _engaged = engage;
    try {
      await _channel.invokeMethod<void>(engage ? 'engage' : 'release');
    } on MissingPluginException {
      // Not Android (tests / iOS shim) — nothing to do.
    } on PlatformException {
      // Window not ready yet; let the next status change retry.
      _engaged = !engage;
    }
  }
}
