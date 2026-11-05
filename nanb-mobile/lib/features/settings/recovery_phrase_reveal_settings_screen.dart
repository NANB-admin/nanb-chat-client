import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/design_tokens.dart';
import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../core/platform/ephemeral_clipboard.dart';
import '../../core/platform/secure_screen.dart';
import '../app_lock/verify_passcode_screen.dart';
import '../onboarding/widgets/nanb_button.dart';
import 'widgets/settings_scaffold.dart';

/// Settings → Account → Recovery phrase. Loads the stored BIP-39 phrase from
/// `RecoveryPhraseStorage` and renders it in the same 24-word grid the
/// onboarding `RecoveryRevealScreen` uses, with copy + hide controls.
class RecoveryPhraseRevealSettingsScreen extends ConsumerStatefulWidget {
  const RecoveryPhraseRevealSettingsScreen({super.key});

  @override
  ConsumerState<RecoveryPhraseRevealSettingsScreen> createState() =>
      _RecoveryPhraseRevealSettingsScreenState();
}

class _RecoveryPhraseRevealSettingsScreenState
    extends ConsumerState<RecoveryPhraseRevealSettingsScreen> {
  String? _phrase;
  bool _revealed = false;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    // Block screenshots / app-switcher snapshots while the phrase screen is up.
    SecureScreen.pushProtected();
    Future.microtask(_load);
  }

  @override
  void dispose() {
    SecureScreen.popProtected();
    super.dispose();
  }

  Future<void> _load() async {
    final phrase = await ref.read(recoveryPhraseStorageProvider).read();
    if (!mounted) return;
    setState(() {
      _phrase = phrase;
      _loading = false;
    });
  }

  /// Hiding is free; revealing the phrase (a full account credential) is gated
  /// behind the app passcode when one is set — so a passcode-locked phone can't
  /// have its recovery phrase read by someone who grabs it unlocked.
  Future<void> _toggleReveal() async {
    if (_revealed) {
      setState(() => _revealed = false);
      return;
    }
    final passcodeSet = await ref.read(passcodeServiceProvider).isSet();
    if (passcodeSet) {
      if (!mounted) return;
      final ok = await Navigator.of(context).push<bool>(
        MaterialPageRoute(
          builder: (_) =>
              const VerifyPasscodeScreen(title: 'Enter passcode to reveal'),
        ),
      );
      if (ok != true) return;
    }
    if (mounted) setState(() => _revealed = true);
  }

  @override
  Widget build(BuildContext context) {
    final t = DesignTokens.of(context);
    return SettingsScaffold(
      title: 'Recovery phrase',
      child: _loading
          ? const Center(child: CircularProgressIndicator())
          : _phrase == null
              ? _MissingState(t: t)
              : _RevealBody(
                  t: t,
                  phrase: _phrase!,
                  revealed: _revealed,
                  onToggleReveal: _toggleReveal,
                ),
    );
  }
}

class _MissingState extends StatelessWidget {
  const _MissingState({required this.t});
  final DesignTokens t;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.warning_amber_rounded, size: 36, color: t.warn),
            const SizedBox(height: 12),
            Text(
              'No phrase on this device',
              style: TextStyle(fontSize: 14, color: t.text),
            ),
            const SizedBox(height: 8),
            Text(
              "This device's local secure storage doesn't have the recovery "
              'phrase. It was either never persisted (older app versions) or '
              'cleared by a delete-account action.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: t.textMuted, height: 1.5),
            ),
          ],
        ),
      ),
    );
  }
}

class _RevealBody extends StatelessWidget {
  const _RevealBody({
    required this.t,
    required this.phrase,
    required this.revealed,
    required this.onToggleReveal,
  });

  final DesignTokens t;
  final String phrase;
  final bool revealed;
  final VoidCallback onToggleReveal;

  List<String> get _words => phrase.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          'Treat this phrase like a password.',
          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: t.text),
        ),
        const SizedBox(height: 6),
        Text(
          "Anyone with these 24 words can sign in as you and impersonate you "
          "to your contacts. We can't help you recover this — write it down "
          "and store it offline.",
          style: TextStyle(fontSize: 12, color: t.textMuted, height: 1.5),
        ),
        const SizedBox(height: 16),
        _WordsGrid(t: t, words: _words, hidden: !revealed),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: NanbButton(
                label: revealed ? 'Hide' : 'Reveal',
                kind: NanbButtonKind.secondary,
                onPressed: onToggleReveal,
                icon: revealed ? Icons.visibility_off_outlined : Icons.visibility_outlined,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: NanbButton(
                label: 'Copy',
                kind: NanbButtonKind.primary,
                onPressed: revealed
                    ? () {
                        copyEphemeral(phrase);
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Recovery phrase copied '
                                '— clipboard clears in 60s'),
                          ),
                        );
                      }
                    : null,
                icon: Icons.copy_outlined,
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: t.danger.withValues(alpha: 0.07),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: t.danger),
          ),
          child: Text(
            'Never type this into another app, share it over chat, or take a '
            'screenshot. Anyone who reads it owns your account.',
            style: monoStyle(fontSize: 11, color: t.danger).copyWith(height: 1.5),
          ),
        ),
      ],
    );
  }
}

class _WordsGrid extends StatelessWidget {
  const _WordsGrid({required this.t, required this.words, required this.hidden});
  final DesignTokens t;
  final List<String> words;
  final bool hidden;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: t.borderStrong),
      ),
      child: Column(
        // Adaptive: 12-word phrases (or custom lengths) get exactly the
        // rows they need; legacy 24-word phrases still show 12 rows.
        children: List.generate((words.length / 2).ceil(), (rowIndex) {
          final half = (words.length / 2).ceil();
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              children: [
                Expanded(child: _cell(rowIndex)),
                const SizedBox(width: 12),
                Expanded(child: _cell(rowIndex + half)),
              ],
            ),
          );
        }),
      ),
    );
  }

  Widget _cell(int i) {
    if (i >= words.length) return const SizedBox.shrink();
    final word = words[i];
    final shown = hidden ? '••••••' : word;
    final num = (i + 1).toString().padLeft(2);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: t.surfaceAlt,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: t.border),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 16,
            child: Text(
              num,
              textAlign: TextAlign.right,
              style: monoStyle(fontSize: 9.5, color: t.textFaint),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              shown,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: monoStyle(fontSize: 12, color: t.text),
            ),
          ),
        ],
      ),
    );
  }
}
