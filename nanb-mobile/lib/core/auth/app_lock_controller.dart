import 'package:flutter/foundation.dart';

/// Tracks whether the app is currently locked behind biometric/passcode auth.
///
/// This holds only the raw lock flag — whether the lock is actually *shown*
/// is the gate's decision (it also checks the `biometricUnlock` /
/// `passcodeEnabled` preferences). Starts locked so a cold start with the
/// feature enabled prompts immediately; the gate is a no-op when off.
///
/// Lifecycle: [lock] is called when the app is backgrounded; [unlock] after a
/// successful auth. An *expected in-app excursion* that backgrounds the app —
/// the camera, a gallery/file picker, the share sheet — would otherwise trip
/// [lock] and re-prompt on return; [suppressNextBackgroundLock] +
/// [resumeFromBackground] bracket such an excursion so it doesn't.
class AppLockController extends ChangeNotifier {
  AppLockController({DateTime Function()? now}) : _now = now ?? DateTime.now;

  /// Injectable clock (tests drive the excursion window).
  final DateTime Function() _now;

  bool _locked = true;
  bool get isLocked => _locked;

  /// While true, [lock] is a no-op — set across an expected excursion that
  /// backgrounds the app so returning from it doesn't re-prompt. Cleared by
  /// [resumeFromBackground].
  bool _suppressBackgroundLock = false;
  DateTime? _suppressStartedAt;

  /// Upper bound on a trusted excursion. If the app stays backgrounded longer
  /// than this, [resumeFromBackground] re-locks on return — a quick hop to the
  /// camera is trusted; wandering off for minutes is treated as a real
  /// background, so an abandoned excursion can't leave the app unlocked.
  static const Duration _suppressWindow = Duration(minutes: 3);

  void lock() {
    if (_suppressBackgroundLock) return; // expected excursion in progress
    if (_locked) return;
    _locked = true;
    notifyListeners();
  }

  void unlock() {
    if (!_locked) return;
    _locked = false;
    notifyListeners();
  }

  /// Marks the start of an expected excursion. Call right before launching the
  /// camera or a system picker so the resulting background doesn't [lock].
  void suppressNextBackgroundLock() {
    _suppressBackgroundLock = true;
    _suppressStartedAt = _now();
  }

  /// Ends excursion suppression on app resume. Re-locks if the excursion ran
  /// longer than [_suppressWindow] (treat as a genuine background, not a quick
  /// picker hop). No-op when no excursion was in progress.
  void resumeFromBackground() {
    if (!_suppressBackgroundLock) return;
    final startedAt = _suppressStartedAt;
    _suppressBackgroundLock = false;
    _suppressStartedAt = null;
    if (startedAt != null && _now().difference(startedAt) > _suppressWindow) {
      lock();
    }
  }
}
