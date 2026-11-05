import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/design_tokens.dart';
import '../../app/providers.dart';
import '../../app/theme.dart';
import '../onboarding/widgets/nanb_button.dart';
import 'passcode_entry.dart';

/// Overlays a full-screen lock above the whole app when an app-lock preference
/// is on (biometric and/or passcode) AND the [AppLockController] is locked.
/// Mounted via `MaterialApp.router`'s `builder`, so it sits above the Navigator
/// and hides every route until the user authenticates.
class AppLockGate extends ConsumerWidget {
  const AppLockGate({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prefs = ref.watch(appPreferencesProvider).value;
    final enabled = prefs.biometricUnlock || prefs.passcodeEnabled;
    final locked = ref.watch(appLockControllerProvider).isLocked;
    return Stack(
      children: [
        child,
        if (enabled && locked) const Positioned.fill(child: _LockScreen()),
      ],
    );
  }
}

class _LockScreen extends ConsumerStatefulWidget {
  const _LockScreen();

  @override
  ConsumerState<_LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends ConsumerState<_LockScreen>
    with WidgetsBindingObserver {
  bool _busy = false;
  bool _failed = false;
  bool _verifyingPin = false;
  String? _pinError;

  bool get _passcodeOn =>
      ref.read(appPreferencesProvider).value.passcodeEnabled;
  bool get _biometricOn =>
      ref.read(appPreferencesProvider).value.biometricUnlock;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Auto-prompt biometric on first show when foregrounded — but only when a
    // passcode isn't the active factor. App lock is one-at-a-time, so a
    // passcode must never be skipped by an automatic biometric unlock. The
    // resume handler covers the background→foreground case.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_biometricOn &&
          !_passcodeOn &&
          WidgetsBinding.instance.lifecycleState ==
              AppLifecycleState.resumed) {
        _authenticateBiometric();
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _biometricOn && !_passcodeOn) {
      _authenticateBiometric();
    }
  }

  Future<void> _authenticateBiometric() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _failed = false;
    });
    final ok = await ref
        .read(appLockServiceProvider)
        .authenticate(reason: 'Unlock Chat');
    if (!mounted) return;
    if (ok) {
      ref.read(appLockControllerProvider).unlock();
    } else {
      setState(() {
        _busy = false;
        _failed = true;
      });
    }
  }

  Future<void> _verifyPin(String pin) async {
    // Guard against a second submission landing while the first PBKDF2 verify
    // is still running — that race is what made the screen feel like it needed
    // the PIN entered several times.
    if (_verifyingPin) return;
    setState(() {
      _verifyingPin = true;
      _pinError = null;
    });
    final svc = ref.read(passcodeServiceProvider);
    final ok = await svc.verify(pin);
    if (!mounted) return;
    if (ok) {
      ref.read(appLockControllerProvider).unlock();
    } else {
      final lock = await svc.lockoutRemaining();
      if (!mounted) return;
      setState(() {
        _verifyingPin = false;
        _pinError = lock != null
            ? 'Too many attempts. Try again in ${_formatLockout(lock)}.'
            : 'Wrong passcode. Try again.';
      });
    }
  }

  /// Compact lockout formatting for the PIN error line ("30s" / "5m").
  String _formatLockout(Duration d) =>
      d.inMinutes >= 1 ? '${d.inMinutes}m' : '${d.inSeconds}s';

  @override
  Widget build(BuildContext context) {
    final t = DesignTokens.of(context);
    return Material(
      color: t.bg,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: _passcodeOn
              ? _buildPasscode(t)
              : _buildBiometricOnly(t),
        ),
      ),
    );
  }

  // Passcode (with biometric as an optional keypad shortcut when also enabled).
  Widget _buildPasscode(DesignTokens t) {
    return Column(
      children: [
        const SizedBox(height: 24),
        Text(
          'Chat',
          style: monoStyle(fontSize: 12, color: t.accent, letterSpacing: 4),
        ),
        const Spacer(),
        PasscodeEntryView(
          title: 'Enter passcode',
          subtitle: 'Enter your passcode to unlock.',
          errorText: _pinError,
          busy: _verifyingPin,
          onCompleted: _verifyPin,
          onBiometric: _biometricOn ? _authenticateBiometric : null,
        ),
        const Spacer(),
      ],
    );
  }

  // Biometric/credential only — the original lock flow.
  Widget _buildBiometricOnly(DesignTokens t) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 36),
        Text(
          'Chat',
          style: monoStyle(fontSize: 12, color: t.accent, letterSpacing: 4),
        ),
        const Spacer(),
        Icon(Icons.lock_outline, size: 44, color: t.text),
        const SizedBox(height: 20),
        Text(
          'Locked',
          textAlign: TextAlign.center,
          style: TextStyle(
              fontSize: 28, fontWeight: FontWeight.w500, color: t.text),
        ),
        const SizedBox(height: 10),
        Text(
          _failed
              ? 'Authentication failed. Try again.'
              : 'Unlock with your biometrics or device PIN to continue.',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 14,
            color: _failed ? t.danger : t.textMuted,
            height: 1.5,
          ),
        ),
        const Spacer(),
        NanbButton(
          label: _busy ? 'Unlocking…' : 'Unlock',
          kind: NanbButtonKind.primary,
          fullWidth: true,
          icon: Icons.fingerprint,
          onPressed: _busy ? null : _authenticateBiometric,
        ),
        const SizedBox(height: 12),
      ],
    );
  }
}
