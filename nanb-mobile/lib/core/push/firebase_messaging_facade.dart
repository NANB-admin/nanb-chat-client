import 'package:flutter/foundation.dart';

import 'package:firebase_messaging/firebase_messaging.dart';

import 'push_permission.dart';

/// Thin testable seam over `FirebaseMessaging.instance`. Production wires
/// to the real plugin; tests inject a fake.
abstract class FirebaseMessagingFacade {
  /// Returns the current FCM token, or null if the device hasn't registered
  /// (e.g., no Firebase project, no Play Services).
  Future<String?> getToken();

  /// Stream of new tokens emitted when the token rotates.
  Stream<String> get onTokenRefresh;

  /// Requests notification permissions — required on iOS + Android 13+.
  /// Returns true if the user granted permission.
  ///
  /// On iOS this only ever prompts ONCE per install: after the user has
  /// answered, the OS resolves it silently with the stored answer. So a
  /// "denied" result here means the user must be sent to system settings —
  /// re-requesting will never show a prompt again.
  Future<bool> requestPermission();

  /// Reads the CURRENT notification permission without prompting.
  ///
  /// Needed to tell the three ways "notifications don't work" apart — OS
  /// permission refused, the in-app push pref off, or no token registered —
  /// which are indistinguishable to a user who has simply "turned notifications
  /// on" somewhere and still hears nothing.
  Future<PushPermission> permissionStatus();

  /// Enables/disables FCM auto-init (token generation + Google connection).
  /// The manifest ships it OFF for privacy; this turns it on only when the
  /// user's push toggle is on. Disabling it stops future token refresh.
  Future<void> setAutoInitEnabled(bool enabled);

  /// Deletes the current FCM token from Google (used when push is turned off),
  /// so the device stops being addressable via FCM right away.
  Future<void> deleteToken();
}

class FirebaseMessagingFacadeImpl implements FirebaseMessagingFacade {
  FirebaseMessagingFacadeImpl({FirebaseMessaging? messaging})
      : _messaging = messaging ?? FirebaseMessaging.instance;

  final FirebaseMessaging _messaging;

  @override
  Future<String?> getToken() async {
    try {
      // iOS: FCM can only mint a registration token once APNs has handed the
      // app its device token, and `registerForRemoteNotifications()` resolves
      // asynchronously after launch. Called too early, `getToken()` throws
      // `apns-token-not-set` (or returns null) — which this catch used to turn
      // into "no token", so the registrar POSTed nothing and the device stayed
      // unreachable by push for the whole session. Give APNs a short window to
      // land first. Android has no such dependency.
      if (defaultTargetPlatform == TargetPlatform.iOS) {
        await _awaitApnsToken();
      }
      return await _messaging.getToken();
    } catch (_) {
      // Placeholder Firebase project, no Play Services, or no network at boot.
      return null;
    }
  }

  /// Waits (briefly) for the APNs device token. Bounded: if the user declined
  /// notification permission there will never be one, and the caller must not
  /// hang on that — it simply falls through and `getToken()` fails as before.
  Future<void> _awaitApnsToken() async {
    for (var attempt = 0; attempt < _apnsTokenAttempts; attempt++) {
      try {
        final apns = await _messaging.getAPNSToken();
        if (apns != null && apns.isNotEmpty) return;
      } catch (_) {/* treat as "not yet" and keep waiting out the window */}
      await Future<void>.delayed(_apnsTokenPollInterval);
    }
  }

  /// ~5s total: long enough for APNs registration on a normal launch, short
  /// enough that a permission-denied device doesn't stall `connect()`.
  static const int _apnsTokenAttempts = 10;
  static const Duration _apnsTokenPollInterval = Duration(milliseconds: 500);

  @override
  Stream<String> get onTokenRefresh => _messaging.onTokenRefresh;

  @override
  Future<bool> requestPermission() async {
    final settings = await _messaging.requestPermission();
    return settings.authorizationStatus == AuthorizationStatus.authorized ||
        settings.authorizationStatus == AuthorizationStatus.provisional;
  }

  @override
  Future<PushPermission> permissionStatus() async {
    try {
      final settings = await _messaging.getNotificationSettings();
      switch (settings.authorizationStatus) {
        case AuthorizationStatus.authorized:
        case AuthorizationStatus.provisional:
          return PushPermission.granted;
        case AuthorizationStatus.denied:
          return PushPermission.denied;
        case AuthorizationStatus.notDetermined:
          return PushPermission.notDetermined;
      }
    } catch (_) {
      // Firebase not initialized (push pref off this session) — we genuinely
      // don't know, and must NOT report that as "denied" or the UI would blame
      // the OS for what is really the in-app toggle.
      return PushPermission.unknown;
    }
  }

  @override
  Future<void> setAutoInitEnabled(bool enabled) async {
    try {
      await _messaging.setAutoInitEnabled(enabled);
    } catch (_) {
      // Firebase not initialized (push off this session) — nothing to toggle.
    }
  }

  @override
  Future<void> deleteToken() async {
    try {
      await _messaging.deleteToken();
    } catch (_) {/* best-effort; no token / no Play Services */}
  }
}
