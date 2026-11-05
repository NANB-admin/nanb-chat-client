import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/design_tokens.dart';
import '../../app/providers.dart';
import '../../app/theme.dart';
import '../app_lock/passcode_entry.dart';
import 'widgets/nanb_button.dart';

/// Unlock challenge shown before a kept-on-device session resumes from the
/// welcome screen ("Continue as @…"). Without it, signing back in was a single
/// tap with no proof of identity. Picks the strongest available factor:
///
///   1. **App passcode** (the in-app PIN), if one is set;
///   2. else the **device biometric / lock screen** (via `local_auth`), if the
///      app-lock biometric preference is on OR the device has any credential
///      enrolled;
///   3. else the **recovery phrase**.
///
/// Pops `true` once the user authenticates, `false`/null if they back out.
///
/// Shown via a raw [Navigator] push (a fullscreen modal), NOT a go_router
/// route: the welcome screen reaches here while the manual-sign-out gate is
/// still up, and go_router's redirect would bounce any named route back to
/// /welcome. A plain Navigator page sidesteps that.
enum _Factor { passcode, deviceAuth, recoveryPhrase, none }

class ResumeAuthScreen extends ConsumerStatefulWidget {
  const ResumeAuthScreen({super.key, required this.handle});

  /// The @handle being resumed, shown in the prompt for context.
  final String handle;

  @override
  ConsumerState<ResumeAuthScreen> createState() => _ResumeAuthScreenState();
}

class _ResumeAuthScreenState extends ConsumerState<ResumeAuthScreen> {
  late final Future<_Factor> _factorFuture = _determineFactor();

  // Passcode state.
  bool _verifyingPin = false;
  String? _pinError;

  // Device-auth state.
  bool _deviceBusy = false;
  bool _deviceFailed = false;
  bool _devicePrompted = false;

  // Recovery-phrase state.
  final _phraseController = TextEditingController();
  bool _checkingPhrase = false;
  String? _phraseError;

  @override
  void dispose() {
    _phraseController.dispose();
    super.dispose();
  }

  Future<_Factor> _determineFactor() async {
    final prefs = ref.read(appPreferencesProvider).value;
    if (prefs.passcodeEnabled &&
        await ref.read(passcodeServiceProvider).isSet()) {
      return _Factor.passcode;
    }
    if (prefs.biometricUnlock ||
        await ref.read(appLockServiceProvider).canAuthenticate()) {
      return _Factor.deviceAuth;
    }
    final phrase = await ref.read(recoveryPhraseStorageProvider).read();
    if (phrase != null && phrase.trim().isNotEmpty) {
      return _Factor.recoveryPhrase;
    }
    // Nothing to verify against (no passcode, no device lock, no stored
    // phrase — e.g. an older account). Fail OPEN rather than locking the user
    // out of their own kept session.
    return _Factor.none;
  }

  void _pass() {
    if (mounted) Navigator.of(context).pop(true);
  }

  Future<void> _verifyPin(String pin) async {
    if (_verifyingPin) return;
    setState(() {
      _verifyingPin = true;
      _pinError = null;
    });
    final ok = await ref.read(passcodeServiceProvider).verify(pin);
    if (!mounted) return;
    if (ok) {
      _pass();
    } else {
      setState(() {
        _verifyingPin = false;
        _pinError = 'Wrong passcode. Try again.';
      });
    }
  }

  Future<void> _authenticateDevice() async {
    if (_deviceBusy) return;
    setState(() {
      _deviceBusy = true;
      _deviceFailed = false;
    });
    final ok = await ref
        .read(appLockServiceProvider)
        .authenticate(reason: 'Sign in to Chat');
    if (!mounted) return;
    if (ok) {
      _pass();
    } else {
      setState(() {
        _deviceBusy = false;
        _deviceFailed = true;
      });
    }
  }

  Future<void> _verifyPhrase() async {
    if (_checkingPhrase) return;
    setState(() {
      _checkingPhrase = true;
      _phraseError = null;
    });
    final stored = await ref.read(recoveryPhraseStorageProvider).read();
    if (!mounted) return;
    final match = stored != null &&
        _normalizePhrase(stored) == _normalizePhrase(_phraseController.text);
    if (match) {
      _pass();
    } else {
      setState(() {
        _checkingPhrase = false;
        _phraseError = "That doesn't match this account's recovery phrase.";
      });
    }
  }

  static String _normalizePhrase(String s) =>
      s.trim().toLowerCase().split(RegExp(r'\s+')).join(' ');

  @override
  Widget build(BuildContext context) {
    final t = DesignTokens.of(context);
    return Scaffold(
      backgroundColor: t.bg,
      appBar: AppBar(
        backgroundColor: t.bg,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.close, color: t.text),
          onPressed: () => Navigator.of(context).pop(false),
        ),
      ),
      body: SafeArea(
        child: FutureBuilder<_Factor>(
          future: _factorFuture,
          builder: (context, snap) {
            if (!snap.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            switch (snap.data!) {
              case _Factor.passcode:
                return _buildPasscode(t);
              case _Factor.deviceAuth:
                return _buildDeviceAuth(t);
              case _Factor.recoveryPhrase:
                return _buildRecoveryPhrase(t);
              case _Factor.none:
                // No factor available — let the resume through.
                WidgetsBinding.instance.addPostFrameCallback((_) => _pass());
                return const Center(child: CircularProgressIndicator());
            }
          },
        ),
      ),
    );
  }

  Widget _buildPasscode(DesignTokens t) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          const Spacer(),
          PasscodeEntryView(
            title: 'Enter passcode',
            subtitle: 'Enter your passcode to sign in as ${widget.handle}.',
            errorText: _pinError,
            busy: _verifyingPin,
            onCompleted: _verifyPin,
          ),
          const Spacer(),
        ],
      ),
    );
  }

  Widget _buildDeviceAuth(DesignTokens t) {
    // Auto-prompt the OS sheet once when this factor first renders.
    if (!_devicePrompted) {
      _devicePrompted = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _authenticateDevice());
    }
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Spacer(),
          Icon(Icons.lock_outline, size: 44, color: t.text),
          const SizedBox(height: 20),
          Text(
            'Confirm it\'s you',
            textAlign: TextAlign.center,
            style: TextStyle(
                fontSize: 26, fontWeight: FontWeight.w500, color: t.text),
          ),
          const SizedBox(height: 10),
          Text(
            _deviceFailed
                ? 'Authentication failed. Try again.'
                : 'Unlock with your biometrics or device PIN to sign in as '
                    '${widget.handle}.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 14,
              color: _deviceFailed ? t.danger : t.textMuted,
              height: 1.5,
            ),
          ),
          const Spacer(),
          NanbButton(
            label: _deviceBusy ? 'Unlocking…' : 'Unlock',
            kind: NanbButtonKind.primary,
            fullWidth: true,
            icon: Icons.fingerprint,
            onPressed: _deviceBusy ? null : _authenticateDevice,
          ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }

  Widget _buildRecoveryPhrase(DesignTokens t) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 12),
          Text(
            'Enter your recovery phrase',
            style: TextStyle(
                fontSize: 22, fontWeight: FontWeight.w500, color: t.text),
          ),
          const SizedBox(height: 8),
          Text(
            'This device has no passcode or screen lock set, so confirm your '
            'recovery phrase to sign in as ${widget.handle}.',
            style: TextStyle(fontSize: 13, color: t.textMuted, height: 1.5),
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _phraseController,
            minLines: 2,
            maxLines: 4,
            autocorrect: false,
            enableSuggestions: false,
            style: monoStyle(fontSize: 14, color: t.text),
            decoration: InputDecoration(
              hintText: 'twelve words separated by spaces',
              hintStyle: monoStyle(fontSize: 13, color: t.textFaint),
              errorText: _phraseError,
              filled: true,
              fillColor: t.surfaceAlt,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(color: t.border),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(color: t.border),
              ),
            ),
          ),
          const SizedBox(height: 16),
          NanbButton(
            label: _checkingPhrase ? 'Checking…' : 'Sign in',
            kind: NanbButtonKind.primary,
            fullWidth: true,
            onPressed: _checkingPhrase ? null : _verifyPhrase,
          ),
        ],
      ),
    );
  }
}
