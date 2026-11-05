import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/design_tokens.dart';
import '../../app/providers.dart';
import 'passcode_entry.dart';

/// Prompts for the current passcode and pops `true` once it verifies. Used to
/// gate sensitive changes (e.g. turning the passcode off) behind the existing
/// PIN. Pops `false` if the user backs out.
class VerifyPasscodeScreen extends ConsumerStatefulWidget {
  const VerifyPasscodeScreen({super.key, this.title = 'Enter passcode'});

  final String title;

  @override
  ConsumerState<VerifyPasscodeScreen> createState() =>
      _VerifyPasscodeScreenState();
}

class _VerifyPasscodeScreenState extends ConsumerState<VerifyPasscodeScreen> {
  String? _error;

  Future<void> _onCompleted(String pin) async {
    final svc = ref.read(passcodeServiceProvider);
    final ok = await svc.verify(pin);
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop(true);
    } else {
      final lock = await svc.lockoutRemaining();
      if (!mounted) return;
      setState(() => _error = lock != null
          ? 'Too many attempts. Try again in '
              '${lock.inMinutes >= 1 ? '${lock.inMinutes}m' : '${lock.inSeconds}s'}.'
          : 'Wrong passcode. Try again.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = DesignTokens.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('App passcode'),
        leading: const BackButton(),
      ),
      backgroundColor: t.bg,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Center(
            child: PasscodeEntryView(
              title: widget.title,
              subtitle: 'Confirm your current passcode.',
              errorText: _error,
              onCompleted: _onCompleted,
            ),
          ),
        ),
      ),
    );
  }
}
