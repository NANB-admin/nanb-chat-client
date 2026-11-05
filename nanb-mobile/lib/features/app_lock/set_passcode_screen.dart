import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/design_tokens.dart';
import '../../app/providers.dart';
import '../../core/auth/passcode_service.dart';
import 'passcode_entry.dart';

/// Two-step "set a passcode" flow: enter a 6-digit PIN, then confirm it.
/// On success it stores the hash, flips the `passcodeEnabled` preference, and
/// pops `true`. Pushed from the Privacy settings toggle.
class SetPasscodeScreen extends ConsumerStatefulWidget {
  const SetPasscodeScreen({super.key});

  @override
  ConsumerState<SetPasscodeScreen> createState() => _SetPasscodeScreenState();
}

class _SetPasscodeScreenState extends ConsumerState<SetPasscodeScreen> {
  String? _first;
  String? _error;
  bool _saving = false;

  Future<void> _onCompleted(String pin) async {
    if (_saving) return;
    if (_first == null) {
      setState(() {
        _first = pin;
        _error = null;
      });
      return;
    }
    if (pin != _first) {
      setState(() {
        _first = null;
        _error = "Passcodes didn't match — start over.";
      });
      return;
    }
    // Hashing (PBKDF2, 100k iterations) + the SecureStorage write take a
    // perceptible beat. Show a "Saving…" state and freeze the keypad so the
    // confirm screen can't be mistaken for "nothing happened" and re-entered.
    setState(() => _saving = true);
    await ref.read(passcodeServiceProvider).setPasscode(pin);
    await ref.read(appPreferencesProvider).setPasscodeEnabled(true);
    // They just set it — don't immediately re-prompt (the controller starts
    // in a locked state, which would otherwise show the lock screen now).
    ref.read(appLockControllerProvider).unlock();
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final t = DesignTokens.of(context);
    final confirming = _first != null;
    return Scaffold(
      appBar: AppBar(
        title: const Text('App passcode'),
        leading: const BackButton(),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Center(
            child: PasscodeEntryView(
              key: ValueKey(confirming),
              title: confirming ? 'Confirm passcode' : 'Set a passcode',
              subtitle:
                  'A ${PasscodeService.length}-digit PIN to unlock the app.',
              errorText: _error,
              busy: _saving,
              busyText: 'Saving…',
              onCompleted: _onCompleted,
            ),
          ),
        ),
      ),
      backgroundColor: t.bg,
    );
  }
}
