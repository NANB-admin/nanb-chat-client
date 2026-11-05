import 'package:permission_handler/permission_handler.dart';

import '../secure_storage/secure_storage.dart';

/// Test seam over the Android "display over other apps" (`SYSTEM_ALERT_WINDOW`)
/// state. Production wires to `permission_handler`; tests inject a fake.
abstract class OverlayPermissionSeam {
  /// True if the app may already draw over other apps.
  Future<bool> isGranted();

  /// Opens the system "display over other apps" settings page for this app
  /// (there is no in-place runtime dialog for this permission).
  Future<void> openSettings();
}

/// Production seam backed by `permission_handler`'s `systemAlertWindow`. On
/// non-Android platforms (and where the plugin isn't available, e.g. tests that
/// forget to inject a fake) every call is a best-effort no-op.
class OverlayPermissionSeamPermissionHandler implements OverlayPermissionSeam {
  @override
  Future<bool> isGranted() async {
    try {
      return await Permission.systemAlertWindow.isGranted;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> openSettings() async {
    try {
      // For SYSTEM_ALERT_WINDOW this launches the overlay-settings activity
      // rather than an in-place dialog.
      await Permission.systemAlertWindow.request();
    } catch (_) {/* not Android / plugin missing */}
  }
}

/// Decides whether to surface the one-time "allow display over other apps"
/// rationale for incoming calls. The permission lets the native
/// `IncomingCallActivity` launch as a full-screen ring even when the device is
/// unlocked and the app is backgrounded; without it Android demotes the call's
/// full-screen intent to a heads-up banner (no ring screen, no ringtone).
///
/// Unlike the OS notification prompt, this permission has no in-place dialog —
/// granting it means a trip to a system settings page — so the caller shows a
/// short in-app rationale first and only opens settings if the user opts in.
class OverlayPermissionGate {
  OverlayPermissionGate({
    required OverlayPermissionSeam seam,
    required SecureStorage storage,
  })  : _seam = seam,
        _storage = storage;

  final OverlayPermissionSeam _seam;
  final SecureStorage _storage;

  /// SecureStorage key recording that we've shown the rationale at least once.
  static const String storageKey = 'calls.overlay_prompted';

  /// True when the one-time rationale should be shown: the user hasn't been
  /// prompted before on this device AND the permission isn't already granted.
  /// Pure read — call [markPrompted] once the rationale is actually shown so it
  /// doesn't reappear. (We intentionally don't mark when already granted, so a
  /// later revoke re-surfaces the rationale.)
  Future<bool> needsPrompt() async {
    if (await _storage.getString(storageKey) == 'true') return false;
    if (await _seam.isGranted()) return false;
    return true;
  }

  /// Records that the rationale was shown, so it only appears once per device.
  Future<void> markPrompted() => _storage.putString(storageKey, 'true');

  /// Opens the system "display over other apps" settings for this app.
  Future<void> openSettings() => _seam.openSettings();
}
