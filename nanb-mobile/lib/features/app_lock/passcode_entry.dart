import 'package:flutter/material.dart';

import '../../app/design_tokens.dart';
import '../../core/auth/passcode_service.dart';

/// A numeric passcode entry surface: a row of dots that fill as digits are
/// typed plus a 3×4 keypad. Calls [onCompleted] with the full PIN once
/// [PasscodeService.length] digits are entered, then clears (the parent
/// decides success/failure and may show [errorText]).
///
/// Stateless w.r.t. correctness — the parent owns verification. An optional
/// [onBiometric] renders a fingerprint key in the keypad's bottom-left.
class PasscodeEntryView extends StatefulWidget {
  const PasscodeEntryView({
    super.key,
    required this.title,
    required this.onCompleted,
    this.subtitle,
    this.errorText,
    this.onBiometric,
    this.busy = false,
    this.busyText = 'Checking…',
  });

  final String title;
  final String? subtitle;
  final String? errorText;
  final ValueChanged<String> onCompleted;
  final VoidCallback? onBiometric;

  /// When true the keypad ignores input and shows [busyText] — set while the
  /// parent does slow work on the entered PIN (PBKDF2 verify, or hashing +
  /// persisting a new one) so it can't be re-triggered by an impatient second
  /// entry.
  final bool busy;

  /// Hint shown in place of the subtitle while [busy]. Defaults to the verify
  /// wording; the set-passcode flow overrides it with "Saving…".
  final String busyText;

  @override
  State<PasscodeEntryView> createState() => _PasscodeEntryViewState();
}

class _PasscodeEntryViewState extends State<PasscodeEntryView> {
  String _entered = '';

  @override
  void didUpdateWidget(PasscodeEntryView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A new error (wrong PIN) clears the dots so the user can retry.
    if (widget.errorText != null && widget.errorText != oldWidget.errorText) {
      _entered = '';
    }
  }

  void _press(String digit) {
    if (widget.busy) return;
    if (_entered.length >= PasscodeService.length) return;
    setState(() => _entered += digit);
    if (_entered.length == PasscodeService.length) {
      final pin = _entered;
      // Defer so the final dot paints, then clear + hand the PIN to the parent
      // (which verifies / advances to the confirm step / unlocks).
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _entered = '');
        widget.onCompleted(pin);
      });
    }
  }

  void _backspace() {
    if (widget.busy) return;
    if (_entered.isEmpty) return;
    setState(() => _entered = _entered.substring(0, _entered.length - 1));
  }

  @override
  Widget build(BuildContext context) {
    final t = DesignTokens.of(context);
    final hasError = widget.errorText != null;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          widget.title,
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.w500, color: t.text),
        ),
        const SizedBox(height: 8),
        Text(
          hasError
              ? widget.errorText!
              : (widget.busy ? widget.busyText : (widget.subtitle ?? '')),
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 13,
            color: hasError ? t.danger : t.textMuted,
            height: 1.5,
          ),
        ),
        const SizedBox(height: 28),
        _Dots(t: t, filled: _entered.length, total: PasscodeService.length, error: hasError),
        const SizedBox(height: 32),
        _Keypad(t: t, onDigit: _press, onBackspace: _backspace, onBiometric: widget.onBiometric),
      ],
    );
  }
}

class _Dots extends StatelessWidget {
  const _Dots({required this.t, required this.filled, required this.total, required this.error});
  final DesignTokens t;
  final int filled;
  final int total;
  final bool error;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (var i = 0; i < total; i++)
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 9),
            width: 14,
            height: 14,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: i < filled
                  ? (error ? t.danger : t.accent)
                  : Colors.transparent,
              border: Border.all(
                color: error ? t.danger : (i < filled ? t.accent : t.border),
                width: 1.5,
              ),
            ),
          ),
      ],
    );
  }
}

class _Keypad extends StatelessWidget {
  const _Keypad({
    required this.t,
    required this.onDigit,
    required this.onBackspace,
    this.onBiometric,
  });
  final DesignTokens t;
  final ValueChanged<String> onDigit;
  final VoidCallback onBackspace;
  final VoidCallback? onBiometric;

  @override
  Widget build(BuildContext context) {
    Widget key(String label, {VoidCallback? onTap, IconData? icon}) {
      return SizedBox(
        width: 76,
        height: 76,
        child: Material(
          color: Colors.transparent,
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap ?? (label.isEmpty ? null : () => onDigit(label)),
            child: Center(
              child: icon != null
                  ? Icon(icon, size: 24, color: t.text)
                  : Text(
                      label,
                      style: TextStyle(
                          fontSize: 26, color: t.text, fontWeight: FontWeight.w400),
                    ),
            ),
          ),
        ),
      );
    }

    Widget row(List<Widget> kids) => Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: kids,
        );

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        row([key('1'), key('2'), key('3')]),
        row([key('4'), key('5'), key('6')]),
        row([key('7'), key('8'), key('9')]),
        row([
          onBiometric != null
              ? key('', onTap: onBiometric, icon: Icons.fingerprint)
              : const SizedBox(width: 76, height: 76),
          key('0'),
          key('', onTap: onBackspace, icon: Icons.backspace_outlined),
        ]),
      ],
    );
  }
}
