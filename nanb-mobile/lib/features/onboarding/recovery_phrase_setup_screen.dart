import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/design_tokens.dart';
import '../../app/providers.dart';
import '../../app/router.dart';
import '../../app/theme.dart';
import '../../core/models/api_error.dart';
import '../../core/platform/ephemeral_clipboard.dart';
import '../../core/platform/secure_screen.dart';
import 'onboarding_notifier.dart';
import 'recovery_phrase.dart';
import 'widgets/nanb_button.dart';
import 'widgets/onb_shell.dart';

/// Step 02/04 — choose + save the recovery phrase, then create the account.
///
/// The phrase seeds the identity keypair, so it has to be settled BEFORE the
/// server sees the account (replacing the old post-creation reveal screen).
/// Default is a generated 12-word BIP-39 mnemonic with a Regenerate button;
/// users can also switch to their own words (min
/// [RecoveryPhrase.minCustomWords], with a prominent strength warning).
class RecoveryPhraseSetupScreen extends ConsumerStatefulWidget {
  const RecoveryPhraseSetupScreen({super.key, required this.username});

  /// Username chosen on the previous step. Account creation happens here,
  /// so taken/on-hold errors surface on this screen.
  final String username;

  @override
  ConsumerState<RecoveryPhraseSetupScreen> createState() =>
      _RecoveryPhraseSetupScreenState();
}

class _RecoveryPhraseSetupScreenState
    extends ConsumerState<RecoveryPhraseSetupScreen> {
  String _generated = RecoveryPhrase.generate();
  final _customController = TextEditingController();
  bool _customMode = false;
  bool _hidden = false;
  bool _busy = false;
  String? _error;

  String get _phrase => _customMode
      ? RecoveryPhrase.normalize(_customController.text)
      : _generated;

  bool get _phraseOk => !_customMode ||
      RecoveryPhrase.meetsCreationStrength(_customController.text);

  @override
  void initState() {
    super.initState();
    // The phrase is the master account secret — never let it land in an
    // app-switcher snapshot or screenshot while this screen is up.
    SecureScreen.pushProtected();
  }

  @override
  void dispose() {
    SecureScreen.popProtected();
    _customController.dispose();
    super.dispose();
  }

  Future<void> _createAccount() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final notifier = OnboardingNotifier(
        apiClient: ref.read(apiClientProvider),
        crypto: ref.read(cryptoBridgeProvider),
        sessions: ref.read(sessionRepositoryProvider),
        phraseStorage: ref.read(recoveryPhraseStorageProvider),
      );
      await notifier.createAccount(
        username: widget.username,
        recoveryPhrase: _phrase,
      );
      if (!mounted) return;
      // A new session exists now — drop the signed-out gates before navigating,
      // or the router bounces this straight back to /welcome (see
      // ConversationsNotifier.clearSignedOutForNewSession).
      ref.read(conversationsProvider).clearSignedOutForNewSession();
      context.go(Routes.chatList);
    } on ApiError catch (e) {
      setState(() => _error = _humanise(e));
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _humanise(ApiError e) {
    switch (e.code) {
      case 'username_taken':
        return '@${widget.username} was just taken — go back and pick '
            'another name.';
      case 'username_on_hold':
        return '@${widget.username} is on a 30-day hold after deletion — '
            'go back and pick another name.';
      case 'identity_key_taken':
        return 'These exact words are already in use by another account — '
            'regenerate or change a word.';
      default:
        return e.message;
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = DesignTokens.of(context);
    final words = _customMode
        ? _customController.text
            .trim()
            .split(RegExp(r'\s+'))
            .where((w) => w.isNotEmpty)
            .toList()
        : _generated.split(' ');
    return Scaffold(
      body: OnbShell(
        subLabel: '02 / 04',
        child: LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: IntrinsicHeight(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Your recovery phrase',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w500,
                        color: t.text,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'These words are the only way to recover '
                      '@${widget.username}. Write them down on paper. Anyone '
                      'with these words can read your future messages.',
                      style: TextStyle(
                          fontSize: 13, color: t.textMuted, height: 1.5),
                    ),
                    const SizedBox(height: 16),
                    if (_customMode) ...[
                      _CustomPhraseField(
                        t: t,
                        controller: _customController,
                        onChanged: (_) => setState(() {}),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '${words.length} words · minimum '
                        '${RecoveryPhrase.minNewCustomWords}',
                        style: monoStyle(
                          fontSize: 10.5,
                          color: _phraseOk ? t.textMuted : t.danger,
                          letterSpacing: 0.3,
                        ),
                      ),
                      const SizedBox(height: 12),
                      _CustomWarning(t: t),
                    ] else ...[
                      _WordsGrid(words: words, hidden: _hidden, t: t),
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          NanbButton(
                            label: 'Regenerate',
                            kind: NanbButtonKind.secondary,
                            icon: Icons.refresh,
                            onPressed: _busy
                                ? null
                                : () => setState(
                                    () => _generated = RecoveryPhrase.generate()),
                          ),
                          const SizedBox(width: 8),
                          NanbButton(
                            label: 'Copy',
                            kind: NanbButtonKind.secondary,
                            icon: Icons.copy_outlined,
                            onPressed: _hidden
                                ? null
                                : () {
                                    copyEphemeral(_generated);
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(
                                        content: Text('Recovery phrase copied '
                                            '— clipboard clears in 60s'),
                                      ),
                                    );
                                  },
                          ),
                          const SizedBox(width: 8),
                          NanbButton(
                            label: _hidden ? 'Show' : 'Hide',
                            kind: NanbButtonKind.secondary,
                            icon: _hidden
                                ? Icons.visibility_outlined
                                : Icons.visibility_off_outlined,
                            onPressed: () =>
                                setState(() => _hidden = !_hidden),
                          ),
                        ],
                      ),
                    ],
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton(
                        onPressed: _busy
                            ? null
                            : () => setState(() => _customMode = !_customMode),
                        child: Text(
                          _customMode
                              ? 'Use generated words instead'
                              : 'Use my own words instead',
                          style: monoStyle(
                            fontSize: 11.5,
                            color: t.accent,
                            letterSpacing: 0.3,
                          ),
                        ),
                      ),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 10),
                        decoration: BoxDecoration(
                          color: t.danger.withValues(alpha: 0.07),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: t.danger),
                        ),
                        child: Text(
                          _error!,
                          style: monoStyle(fontSize: 11, color: t.danger)
                              .copyWith(height: 1.5),
                        ),
                      ),
                    ],
                    const Spacer(),
                    const SizedBox(height: 12),
                    _DangerCallout(t: t),
                    const SizedBox(height: 12),
                    NanbButton(
                      label: _busy
                          ? 'Creating…'
                          : "I've saved it — create account",
                      kind: NanbButtonKind.primary,
                      fullWidth: true,
                      onPressed:
                          (_busy || !_phraseOk) ? null : _createAccount,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CustomPhraseField extends StatelessWidget {
  const _CustomPhraseField({
    required this.t,
    required this.controller,
    required this.onChanged,
  });
  final DesignTokens t;
  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: t.borderStrong),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: TextField(
        controller: controller,
        onChanged: onChanged,
        autocorrect: false,
        enableSuggestions: false,
        maxLines: 4,
        minLines: 3,
        decoration: const InputDecoration(
          border: InputBorder.none,
          contentPadding: EdgeInsets.symmetric(vertical: 12),
          hintText: 'correct horse battery staple …',
        ),
        style: monoStyle(fontSize: 14, color: t.text),
      ),
    );
  }
}

/// Strength warning for user-supplied phrases — the phrase derives the
/// identity key, so a guessable one is an account takeover.
class _CustomWarning extends StatelessWidget {
  const _CustomWarning({required this.t});
  final DesignTokens t;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: t.danger.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: t.danger),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(Icons.warning_amber_rounded, size: 14, color: t.danger),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'A custom phrase is only as strong as you make it. Anyone who '
              'guesses these words takes over your account — avoid lyrics, '
              'quotes, names and dates.',
              style: monoStyle(fontSize: 11, color: t.danger)
                  .copyWith(height: 1.5),
            ),
          ),
        ],
      ),
    );
  }
}

class _WordsGrid extends StatelessWidget {
  const _WordsGrid({required this.words, required this.hidden, required this.t});
  final List<String> words;
  final bool hidden;
  final DesignTokens t;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: t.border),
      ),
      child: Column(
        children: List.generate(
          (words.length / 2).ceil(),
          (rowIndex) => Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              children: [
                Expanded(child: _wordCell(rowIndex * 2)),
                const SizedBox(width: 18),
                Expanded(child: _wordCell(rowIndex * 2 + 1)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _wordCell(int i) {
    if (i >= words.length) return const SizedBox.shrink();
    final num = (i + 1).toString().padLeft(2);
    final wordText = hidden ? '·' * words[i].length : words[i];
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        SizedBox(
          width: 22,
          child: Text(
            num,
            textAlign: TextAlign.right,
            style: monoStyle(fontSize: 10, color: t.textFaint),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            wordText,
            style: monoStyle(fontSize: 13, color: t.text),
          ),
        ),
      ],
    );
  }
}

class _DangerCallout extends StatelessWidget {
  const _DangerCallout({required this.t});
  final DesignTokens t;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: t.danger.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: t.danger),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(Icons.warning_amber_rounded, size: 14, color: t.danger),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              "We can't help you recover this. If you lose it, your account is gone.",
              style: monoStyle(fontSize: 11, color: t.danger).copyWith(height: 1.5),
            ),
          ),
        ],
      ),
    );
  }
}
