import 'dart:async';

import 'package:flutter/services.dart';

/// Thin wrapper over the iOS `nanb.app/voip_push` channel — PushKit + CallKit.
///
/// PushKit is what lets a LOCKED iPhone ring: an ordinary alert push runs no
/// app code and shows a passive banner, so an incoming call was easily missed
/// among chat notifications. A VoIP push reaches the app even suspended or
/// never-launched, and the native side reports it to CallKit immediately (it
/// must — iOS kills an app that doesn't).
///
/// This class is DELIBERATELY dumb: it moves messages, and owns no call state.
/// The state machine stays in `CallController`, bridged by `CallKitBridge`.
///
/// A no-op off iOS: every method swallows [MissingPluginException], so Android
/// (which rings from its own FCM data wakeup) and tests need no special casing.
class VoipPushChannel {
  VoipPushChannel({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('nanb.app/voip_push');

  final MethodChannel _channel;

  final StreamController<String> _tokens = StreamController<String>.broadcast();

  /// Incoming-call pushes, as the raw string payload the server sent
  /// (`envelope_id`, `conversation_id`, `push_kind`, `sealed_payload`).
  final StreamController<Map<String, String>> _incoming =
      StreamController<Map<String, String>>.broadcast();

  /// The user answered from the system call UI.
  final StreamController<void> _answers = StreamController<void>.broadcast();

  /// The user declined / hung up from the system call UI (or the OS reset the
  /// provider out from under us).
  final StreamController<void> _ends = StreamController<void>.broadcast();

  Stream<String> get tokens => _tokens.stream;
  Stream<Map<String, String>> get incomingCalls => _incoming.stream;
  Stream<void> get answers => _answers.stream;
  Stream<void> get ends => _ends.stream;

  /// Starts listening and REPLAYS anything the native side buffered while no
  /// Flutter engine was attached. The replay is the cold-launch path: with the
  /// app killed, the push and the answer tap both happen seconds before Dart
  /// exists, so without it answering from the lock screen would do nothing.
  Future<void> start() async {
    _channel.setMethodCallHandler(_onNativeCall);
    for (final event in await takePendingEvents()) {
      _dispatch(event);
    }
  }

  Future<void> _onNativeCall(MethodCall call) async {
    final args = call.arguments;
    _dispatch({
      'event': call.method,
      if (args is Map)
        for (final e in args.entries)
          if (e.key is String && e.value is String)
            e.key as String: e.value as String,
    });
  }

  void _dispatch(Map<String, String> event) {
    switch (event['event']) {
      case 'voipToken':
        final t = event['token'];
        if (t != null && t.isNotEmpty) _tokens.add(t);
      case 'incomingCall':
        _incoming.add(event);
      case 'answerCall':
        _answers.add(null);
      case 'endCall':
        _ends.add(null);
    }
  }

  /// The current PushKit token, or null off iOS / before registration lands.
  Future<String?> currentToken() async {
    try {
      return await _channel.invokeMethod<String>('getToken');
    } on MissingPluginException {
      return null; // not iOS
    } on PlatformException {
      return null;
    }
  }

  Future<List<Map<String, String>>> takePendingEvents() async {
    try {
      final raw = await _channel.invokeMethod<List<Object?>>('takePendingEvents');
      if (raw == null) return const [];
      return [
        for (final item in raw)
          if (item is Map)
            {
              for (final e in item.entries)
                if (e.key is String && e.value is String)
                  e.key as String: e.value as String,
            },
      ];
    } on MissingPluginException {
      return const [];
    } on PlatformException {
      return const [];
    }
  }

  /// Replaces the name the system call UI shows. The push is content-blind
  /// (and conversation-blind under sealed sender), so the native side reports
  /// the ring as just "Chat" and this fills in the peer once Dart knows it.
  Future<void> updateCaller(String name) async {
    if (name.isEmpty) return;
    try {
      await _channel.invokeMethod<void>('updateCaller', {'name': name});
    } on MissingPluginException {
      // not iOS
    } on PlatformException {
      // best-effort; the generic name stands
    }
  }

  /// Dismisses the system call UI. MUST be called whenever the Dart call ends
  /// for any reason — including "we decided not to ring after all" (blocked or
  /// non-callable peer) — or a phantom ring stays on screen with nothing
  /// behind it.
  Future<void> endCall() async {
    try {
      await _channel.invokeMethod<void>('endCall');
    } on MissingPluginException {
      // not iOS
    } on PlatformException {
      // best-effort
    }
  }

  Future<void> dispose() async {
    _channel.setMethodCallHandler(null);
    await _tokens.close();
    await _incoming.close();
    await _answers.close();
    await _ends.close();
  }
}
