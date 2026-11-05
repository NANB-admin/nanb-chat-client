import '../../core/push/push_permission.dart';

/// Turns notifications on from Settings, and reports why they are off.
///
/// The same sequence used to exist ONLY inside the one-time install-time
/// opt-in prompt (`maybeShowPushOptIn`), which never reappears once answered —
/// so a user who tapped "Not now", or who granted the OS permission but left
/// the in-app push pref off, had no route back from anywhere in the app. Every
/// screen they could reach said notifications were enabled while the server
/// held no token for their device and could not wake it at all.
///
/// Collaborators are injected as plain callbacks rather than the concrete
/// notifier/registrar/Firebase types, so the ordering rules below are testable
/// without Riverpod, Firebase, or a platform channel.
class PushEnableService {
  PushEnableService({
    required Future<void> Function(bool) setAppNotificationsEnabled,
    required Future<void> Function(bool) setPushOverFcmEnabled,
    required Future<void> Function()? activateFcm,
    required Future<bool> Function() requestPermission,
    required Future<PushPermission> Function() readPermission,
    required Future<void> Function() registerToken,
    required Future<bool> Function() openSystemSettings,
  })  : _setAppNotificationsEnabled = setAppNotificationsEnabled,
        _setPushOverFcmEnabled = setPushOverFcmEnabled,
        _activateFcm = activateFcm,
        _requestPermission = requestPermission,
        _readPermission = readPermission,
        _registerToken = registerToken,
        _openSystemSettings = openSystemSettings;

  final Future<void> Function(bool) _setAppNotificationsEnabled;
  final Future<void> Function(bool) _setPushOverFcmEnabled;
  final Future<void> Function()? _activateFcm;
  final Future<bool> Function() _requestPermission;
  final Future<PushPermission> Function() _readPermission;
  final Future<void> Function() _registerToken;
  final Future<bool> Function() _openSystemSettings;

  /// Reads the current OS permission without prompting.
  Future<PushPermission> permission() => _readPermission();

  /// Runs the whole enable chain and returns the permission we ended up with.
  ///
  /// Idempotent, and deliberately unconditional: re-running it is the repair
  /// for a half-configured device (pref on but no token, permission granted but
  /// FCM never initialized), which is exactly the state that produces "I turned
  /// notifications on and still get nothing".
  ///
  /// Order is load-bearing:
  ///  1. both in-app prefs first — the FCM providers read them, so flipping
  ///     them later would leave this session using the old values;
  ///  2. bring Firebase up, or there is nothing to ask permission for and no
  ///     token to mint;
  ///  3. ask the OS;
  ///  4. register, which is the only step the SERVER can observe.
  ///
  /// Step 4 runs even when permission was refused: on Android a token can still
  /// exist and data wakeups still arrive, and re-registering repairs a token
  /// the server rejected earlier. A [PushPermission.denied] return means the
  /// caller should offer [openSystemSettings] — on iOS the OS prompt never
  /// appears twice, so no amount of retrying here will help.
  Future<PushPermission> enable() async {
    await _setAppNotificationsEnabled(true);
    await _setPushOverFcmEnabled(true);
    try {
      await _activateFcm?.call();
    } catch (_) {
      // Backstopped: main() initializes FCM on the next launch from the pref
      // we just wrote, so this is a delay, not a failure.
    }
    try {
      await _requestPermission();
    } catch (_) {
      // Firebase unavailable — fall through and still try to register, then
      // report whatever the permission actually reads as.
    }
    try {
      await _registerToken();
    } catch (_) {/* registrar is best-effort; next connect re-POSTs */}
    return _readPermission();
  }

  /// Opens this app's entry in system settings. The only route back once the OS
  /// permission has been refused.
  Future<bool> openSystemSettings() => _openSystemSettings();
}
