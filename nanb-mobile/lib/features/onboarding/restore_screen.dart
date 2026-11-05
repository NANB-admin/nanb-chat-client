import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/design_tokens.dart';
import '../../app/providers.dart';
import '../../app/router.dart';
import '../../app/theme.dart';
import '../../core/models/api_error.dart';
import 'recovery_phrase.dart';
import 'restore_notifier.dart';
import 'widgets/nanb_button.dart';
import 'widgets/onb_shell.dart';

/// Translated from `ScreenRestore` in the design source. 12-cell two-column
/// grid showing typed words + counter. Real BIP-39 validation; the actual
/// device-link flow against the server is a follow-up (placeholder snackbar).
class RestoreScreen extends ConsumerStatefulWidget {
  const RestoreScreen({super.key});

  @override
  ConsumerState<RestoreScreen> createState() => _RestoreScreenState();
}

class _RestoreScreenState extends ConsumerState<RestoreScreen> {
  final _username = TextEditingController();
  final _input = TextEditingController();
  String? _error;
  bool _busy = false;

  List<String> _typedWords() {
    return _input.text
        .trim()
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList();
  }

  Future<void> _restore() async {
    final username = _username.text.trim().replaceAll(RegExp(r'^@'), '').toLowerCase();
    if (username.isEmpty) {
      setState(
        () => _error =
            'Enter your @username so we know which account to restore.',
      );
      return;
    }
    final words = _typedWords();
    // Generated phrases are 12 BIP-39 words (24 for pre-2026-06 accounts);
    // custom phrases just need the minimum word count. The server's
    // signature check is the real gate — a typo'd phrase derives the wrong
    // key and comes back as bad_signature.
    if (words.length < RecoveryPhrase.minCustomWords) {
      setState(
        () => _error = 'Need at least ${RecoveryPhrase.minCustomWords} '
            'words (have ${words.length}).',
      );
      return;
    }
    final phrase = words.join(' ');
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(restoreNotifierProvider)
          .restoreFromPhrase(username: username, phrase: phrase);
      if (!mounted) return;
      // Restoring establishes a new session — drop the signed-out gates before
      // navigating (see ConversationsNotifier.clearSignedOutForNewSession).
      ref.read(conversationsProvider).clearSignedOutForNewSession();
      context.go(Routes.chatList);
    } on InvalidRecoveryPhraseException {
      setState(() => _error = "That phrase can't be used. Check the words.");
    } on ApiError catch (e) {
      setState(() => _error = _humanise(e));
    } catch (e) {
      setState(() => _error = 'Restore failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _humanise(ApiError e) {
    switch (e.code) {
      case 'account_not_found':
        return 'No account matches that username on this server.';
      case 'bad_signature':
        return 'The recovery phrase doesn\'t match the account on this server.';
      case 'challenge_expired':
      case 'challenge_not_found':
        return 'Restore took too long, please try again.';
      default:
        return e.message;
    }
  }

  @override
  void dispose() {
    _username.dispose();
    _input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = DesignTokens.of(context);
    final words = _typedWords();
    return Scaffold(
      body: OnbShell(
        subLabel: 'restore',
        child: LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: IntrinsicHeight(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Restore your account',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w500,
                        color: t.text,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      "Enter your @username and recovery phrase. We'll re-derive your identity key on this device.",
                      style: TextStyle(
                        fontSize: 13,
                        color: t.textMuted,
                        height: 1.5,
                      ),
                    ),
                    const SizedBox(height: 16),
                    _UsernameInput(t: t, controller: _username),
                    const SizedBox(height: 12),
                    _PhraseInput(
                      t: t,
                      controller: _input,
                      onChanged: (_) => setState(() {}),
                    ),
                    const SizedBox(height: 8),
                    _WordsGrid(t: t, typed: words),
                    const SizedBox(height: 8),
                    Text(
                      '${words.length} words',
                      style: monoStyle(
                        fontSize: 10.5,
                        color: t.textMuted,
                        letterSpacing: 0.3,
                      ),
                    ),
                    const SizedBox(height: 16),
                    _NoteCard(t: t),
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: t.danger.withValues(alpha: 0.07),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: t.danger),
                        ),
                        child: Text(
                          _error!,
                          style: monoStyle(
                            fontSize: 11,
                            color: t.danger,
                          ).copyWith(height: 1.5),
                        ),
                      ),
                    ],
                    const Spacer(),
                    NanbButton(
                      label: _busy ? 'Validating…' : 'Restore',
                      kind: NanbButtonKind.primary,
                      fullWidth: true,
                      onPressed: _busy ? null : _restore,
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

class _UsernameInput extends StatelessWidget {
  const _UsernameInput({required this.t, required this.controller});
  final DesignTokens t;
  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: t.borderStrong),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          Text('@', style: monoStyle(fontSize: 14, color: t.textMuted)),
          const SizedBox(width: 4),
          Expanded(
            child: TextField(
              controller: controller,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(
                border: InputBorder.none,
                contentPadding: EdgeInsets.symmetric(vertical: 12),
                hintText: 'username',
              ),
              style: monoStyle(fontSize: 14, color: t.text),
            ),
          ),
        ],
      ),
    );
  }
}

class _PhraseInput extends StatelessWidget {
  const _PhraseInput({
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
        maxLines: null,
        decoration: const InputDecoration(
          border: InputBorder.none,
          contentPadding: EdgeInsets.symmetric(vertical: 12),
          hintText: 'orbit pelican marble crisp …',
        ),
        style: monoStyle(fontSize: 14, color: t.text),
      ),
    );
  }
}

class _WordsGrid extends StatelessWidget {
  const _WordsGrid({required this.t, required this.typed});
  final DesignTokens t;
  final List<String> typed;

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
        // 6 rows (12 cells) minimum; grows for longer phrases (legacy
        // 24-word, long custom). Column-major like the setup screen.
        children: List.generate(
          ((typed.length > 12 ? typed.length : 12) / 2).ceil(),
          (rowIndex) {
            final half =
                ((typed.length > 12 ? typed.length : 12) / 2).ceil();
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                children: [
                  Expanded(child: _wordCell(rowIndex)),
                  const SizedBox(width: 12),
                  Expanded(child: _wordCell(rowIndex + half)),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _wordCell(int i) {
    final filled = i < typed.length;
    final num = (i + 1).toString().padLeft(2);
    final wordText = filled ? typed[i] : '·';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: t.surfaceAlt,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: filled ? t.border : Colors.transparent),
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
              wordText,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: monoStyle(
                fontSize: 12,
                color: filled ? t.text : t.textFaint,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _NoteCard extends StatelessWidget {
  const _NoteCard({required this.t});
  final DesignTokens t;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: t.surfaceAlt,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: t.border),
      ),
      child: Text.rich(
        TextSpan(
          style: TextStyle(fontSize: 12, color: t.textMuted, height: 1.5),
          children: [
            const TextSpan(
              text:
                  'Restoring will recover your username and ability to receive new messages. It will ',
            ),
            TextSpan(
              text: 'not',
              style: TextStyle(color: t.text, fontStyle: FontStyle.italic),
            ),
            const TextSpan(
              text:
                  ' recover old messages, media, or group memberships — those live only on your previous devices.',
            ),
          ],
        ),
      ),
    );
  }
}
