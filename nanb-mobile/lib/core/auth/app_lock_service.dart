import 'package:local_auth/local_auth.dart';

/// Thin seam over device biometric / credential authentication. Abstracted so
/// the lock UI and settings can be unit-tested without the platform plugin.
abstract class AppLockService {
  /// True when the device can authenticate the user — either a biometric is
  /// enrolled, or a device credential (PIN/pattern/password) is set.
  Future<bool> canAuthenticate();

  /// Prompts the OS biometric/credential sheet. Returns true on success,
  /// false if the user cancelled or failed. [reason] is shown on the sheet.
  Future<bool> authenticate({required String reason});
}

/// Production implementation backed by the `local_auth` plugin.
class AppLockServiceLocalAuth implements AppLockService {
  AppLockServiceLocalAuth([LocalAuthentication? auth])
    : _auth = auth ?? LocalAuthentication();

  final LocalAuthentication _auth;

  @override
  Future<bool> canAuthenticate() async {
    try {
      // isDeviceSupported() covers device-credential fallback; canCheckBiometrics
      // covers enrolled biometrics. Either is enough to gate the app.
      final supported = await _auth.isDeviceSupported();
      return supported;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> authenticate({required String reason}) async {
    try {
      return await _auth.authenticate(
        localizedReason: reason,
        options: const AuthenticationOptions(
          // Keep the sheet up across app backgrounding (e.g. the system
          // biometric overlay) and allow PIN/pattern/password fallback so a
          // user without enrolled biometrics can still unlock.
          stickyAuth: true,
          biometricOnly: false,
        ),
      );
    } catch (_) {
      // Plugin throws on no-hardware / not-enrolled / lockout. Treat any
      // failure as "not authenticated" — the lock screen stays up.
      return false;
    }
  }
}
