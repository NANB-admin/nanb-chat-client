import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/design_tokens.dart';
import '../../app/providers.dart';
import '../../app/router.dart';
import '../../app/theme.dart';
import '../../core/models/api_error.dart';
import 'widgets/nanb_button.dart';
import 'widgets/onb_shell.dart';

/// Translated from `ScreenUsername`. Mono `@`-prefixed input + heads-up box +
/// continue button. Continue asks the server whether the name is available
/// (taken / 30-day hold) BEFORE pushing the recovery-phrase screen, so the
/// user never invests in a phrase for a name they can't have. Creation still
/// re-checks server-side — a name can be sniped between screens, and that
/// race surfaces on the phrase screen.
class UsernameScreen extends ConsumerStatefulWidget {
  const UsernameScreen({super.key});

  @override
  ConsumerState<UsernameScreen> createState() => _UsernameScreenState();
}

class _UsernameScreenState extends ConsumerState<UsernameScreen> {
  final _controller = TextEditingController();
  String? _error;
  bool _checking = false;

  bool get _isValidLocal {
    // Any case may be typed; usernames are saved lowercase.
    final v = _controller.text.trim().toLowerCase();
    if (v.length < 3 || v.length > 32) return false;
    return RegExp(r'^[a-z0-9_-]+$').hasMatch(v);
  }

  Future<void> _continue() async {
    final username = _controller.text.trim().toLowerCase();
    setState(() {
      _checking = true;
      _error = null;
    });
    try {
      final avail =
          await ref.read(apiClientProvider).checkUsername(username);
      if (!mounted) return;
      if (avail.available) {
        context.push(Routes.recoverySetup, extra: username);
      } else {
        setState(() => _error = switch (avail.reason) {
              'taken' => '@$username is already taken',
              'on_hold' =>
                '@$username was recently deleted and is on a 30-day hold',
              _ => '@$username is not a valid username',
            });
      }
    } on ApiError catch (e) {
      // Transport/server failure — creation would fail the same way, so
      // block here rather than letting the user save a phrase first.
      setState(() => _error = e.code == 'network'
          ? "can't reach the server — check your connection"
          : e.message);
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = DesignTokens.of(context);
    return Scaffold(
      body: OnbShell(
        subLabel: '01 / 04',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Choose a username',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w500, color: t.text),
            ),
            const SizedBox(height: 8),
            Text(
              '3–32 characters, lowercase letters, numbers, dashes and underscores. '
              'Your username is how others find you.',
              style: TextStyle(fontSize: 13, color: t.textMuted, height: 1.5),
            ),
            const SizedBox(height: 24),
            _UsernameField(
              controller: _controller,
              onChanged: (_) => setState(() => _error = null),
              isValid: _isValidLocal,
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: monoStyle(fontSize: 11, color: t.danger, letterSpacing: 0.3),
              ),
            ] else if (_isValidLocal) ...[
              const SizedBox(height: 8),
              Text(
                '✓ format ok',
                style: monoStyle(fontSize: 11, color: t.accent, letterSpacing: 0.3),
              ),
            ],
            const SizedBox(height: 24),
            _HeadsUp(t: t),
            const Spacer(),
            NanbButton(
              label: _checking ? 'Checking…' : 'Continue',
              kind: NanbButtonKind.primary,
              fullWidth: true,
              onPressed: (_isValidLocal && !_checking) ? _continue : null,
            ),
          ],
        ),
      ),
    );
  }
}

class _UsernameField extends StatelessWidget {
  const _UsernameField({
    required this.controller,
    required this.onChanged,
    required this.isValid,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final bool isValid;

  @override
  Widget build(BuildContext context) {
    final t = DesignTokens.of(context);
    return Container(
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: t.borderStrong),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: Text(
              '@',
              style: monoStyle(fontSize: 16, color: t.textFaint),
            ),
          ),
          Expanded(
            child: TextField(
              controller: controller,
              onChanged: onChanged,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(
                border: InputBorder.none,
                contentPadding: EdgeInsets.symmetric(vertical: 14),
              ),
              style: monoStyle(fontSize: 16, color: t.text),
            ),
          ),
          if (isValid)
            Icon(Icons.check, size: 18, color: t.accent),
        ],
      ),
    );
  }
}

class _HeadsUp extends StatelessWidget {
  const _HeadsUp({required this.t});
  final DesignTokens t;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: t.surfaceAlt,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: t.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'HEADS UP',
            style: monoStyle(
              fontSize: 10.5,
              color: t.textFaint,
              letterSpacing: 0.4,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Usernames are public on this server. If you delete your account, '
            'the name is held for 30 days before anyone can re-register it.',
            style: TextStyle(
              fontSize: 12.5,
              color: t.textMuted,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}
