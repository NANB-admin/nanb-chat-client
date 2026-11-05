import 'dart:async';

import 'package:flutter/services.dart';

/// Controls the platform screenshot/recording protection on the app window
/// (Android `FLAG_SECURE`; iOS covers the screen only while it's being captured
/// for recording/mirroring — iOS can't block a still screenshot — see
/// `ios/Runner/SecureScreenChannel.swift`). Two inputs are OR'd together:
///
///   - **global**: the user's own "block screenshots" preference — the whole
///     app is secure while it's on (set at boot + on toggle).
///   - **protected routes**: a counter pushed/popped by screens viewing a
///     conversation whose PEER blocks screenshots (`Conversation.
///     peerBlocksScreenshots`). The flag is window-level, so it covers
///     anything stacked on top of the thread (media viewer, profile) too.
///
/// All calls are best-effort no-ops where the channel isn't registered (unit
/// tests) — the invoke just throws [MissingPluginException], which is caught.
///
/// On iOS the OS can't truly PREVENT a still screenshot, so the native side
/// reports `userDidTakeScreenshot` back here while secure is on; listen to
/// [screenshots] to warn the user / notify the peer. Android blocks the capture
/// outright, so [screenshots] never fires there.
class SecureScreen {
  SecureScreen._();

  static const MethodChannel _channel = MethodChannel('nanb.app/secure_screen');

  static bool _global = false;
  static int _protectedRoutes = 0;
  static bool _lastApplied = false;
  static bool _everApplied = false;
  static bool _handlerRegistered = false;

  /// Fires when the OS reports a screenshot was taken while the screen was in a
  /// protected (secure) state. iOS-only (Android blocks the capture, so nothing
  /// to report). Broadcast — events with no listener are dropped.
  static final StreamController<void> _screenshots =
      StreamController<void>.broadcast();
  static Stream<void> get screenshots => _screenshots.stream;

  /// Registers the native → Dart screenshot callback. Idempotent; safe to call
  /// at app start (also armed lazily by the first [setGlobal] / [pushProtected]).
  static void init() => _ensureHandler();

  static void _ensureHandler() {
    if (_handlerRegistered) return;
    _handlerRegistered = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onScreenshot') _screenshots.add(null);
      return null;
    });
  }

  /// Sets the app-wide secure flag (the user's own preference).
  static Future<void> setGlobal(bool enabled) {
    _ensureHandler();
    _global = enabled;
    return _apply();
  }

  /// A screen showing screenshot-protected content appeared. Balanced by
  /// [popProtected] (callers must pop exactly once per push).
  static Future<void> pushProtected() {
    _ensureHandler();
    _protectedRoutes++;
    return _apply();
  }

  /// A screenshot-protected screen went away.
  static Future<void> popProtected() {
    if (_protectedRoutes > 0) _protectedRoutes--;
    return _apply();
  }

  static Future<void> _apply() async {
    final secure = _global || _protectedRoutes > 0;
    // Skip redundant channel hops, but always send the very first state so
    // the window flag matches even when the first computed value is false.
    if (_everApplied && secure == _lastApplied) return;
    _lastApplied = secure;
    _everApplied = true;
    try {
      await _channel.invokeMethod<void>('setSecure', {'secure': secure});
    } on MissingPluginException {
      // Not Android (tests / iOS shim) — nothing to secure.
    } on PlatformException {
      // Window not ready yet; the next state change retries.
      _everApplied = false;
    }
  }
}
