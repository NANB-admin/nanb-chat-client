import '../secure_storage/secure_storage.dart';
import 'firebase_messaging_facade.dart';

/// Test seam over the OS-level "notifications allowed?" prompt. On Android
/// 13+ this surfaces the POST_NOTIFICATIONS runtime permission; on iOS the
/// `UNUserNotificationCenter` authorization request.
abstract class NotificationPermissionSeam {
  /// Returns true if the user granted (or had already granted) permission.
  Future<bool> request();
}

/// Production seam backed by `FirebaseMessaging.requestPermission`, which
/// handles iOS + Android 13+ uniformly.
class NotificationPermissionSeamFcm implements NotificationPermissionSeam {
  NotificationPermissionSeamFcm(this._facade);
  final FirebaseMessagingFacade _facade;

  @override
  Future<bool> request() => _facade.requestPermission();
}

/// Stub used when Firebase init failed at boot (placeholder google-services,
/// no Play Services). Behaves as if the user declined — the registrar will
/// silently skip token registration anyway.
class NotificationPermissionSeamStub implements NotificationPermissionSeam {
  @override
  Future<bool> request() async => false;
}

/// Gates the OS notification-permission prompt so the user only sees it once
/// per device. Subsequent cold-starts trust the OS to remember the user's
/// answer — re-enabling is done from system settings, not by re-prompting.
class NotificationPermissionGate {
  NotificationPermissionGate({
    required NotificationPermissionSeam seam,
    required SecureStorage storage,
  })  : _seam = seam,
        _storage = storage;

  final NotificationPermissionSeam _seam;
  final SecureStorage _storage;

  /// SecureStorage key recording that we've shown the OS prompt at least once.
  ///
  /// Versioned (`.v2`): pre-FCM-on-iOS builds gated Firebase off on iOS, so this
  /// gate ran with a no-op stub seam yet still persisted the v1 flag — which
  /// would suppress the *real* permission prompt on the first FCM-capable iOS
  /// build. Bumping the key forces exactly one re-prompt when push goes live;
  /// platforms that already granted short-circuit silently inside the OS.
  static const String storageKey = 'push.notification_prompted.v2';

  /// Surfaces the OS permission prompt on the first call only. No-op if a
  /// previous call already prompted (even if the user denied).
  Future<void> requestIfFirstTime() async {
    final already = await _storage.getString(storageKey);
    if (already == 'true') return;
    try {
      await _seam.request();
    } finally {
      // Mark prompted even on seam failure — re-trying would just re-spam.
      await _storage.putString(storageKey, 'true');
    }
  }
}
