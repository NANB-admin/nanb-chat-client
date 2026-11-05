import 'package:flutter/services.dart';

/// Posts / cancels the native incoming-call notification, whose full-screen
/// intent targets the native `IncomingCallActivity` — a statically-declared
/// `showWhenLocked` activity that PERSISTS over a secure lock (unlike the Flutter
/// MainActivity, which the keyguard reclaimed after a few seconds).
///
/// The `nanb.app/call_native` channel is registered by the nanb_crypto plugin on
/// EVERY engine, including the FCM background isolate's — so [showIncomingCall]
/// works from the decrypt-free background handler.
///
/// Best-effort no-op off Android (tests / iOS shim).
class CallNative {
  CallNative._();

  static const MethodChannel _channel = MethodChannel('nanb.app/call_native');

  static Future<void> showIncomingCall({
    required int id,
    required String conversationId,
    required String caller,
  }) async {
    try {
      await _channel.invokeMethod<void>('showIncomingCall', {
        'id': id,
        'conversationId': conversationId,
        'caller': caller,
      });
    } on MissingPluginException {
      // Not Android (tests / iOS shim).
    } on PlatformException {
      // Best-effort; a failed post just means no ring this time.
    }
  }

  static Future<void> cancelIncomingCall(int id) async {
    try {
      await _channel.invokeMethod<void>('cancelIncomingCall', {'id': id});
    } on MissingPluginException {
      // Not Android.
    } on PlatformException {
      // Best-effort.
    }
  }
}
