import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/design_tokens.dart';
import '../../app/providers.dart';
import '../../app/router.dart';
import '../../app/theme.dart';
import '../../core/models/jwt_session.dart';
import 'local_account_wipe.dart';
import 'resume_auth_screen.dart';
import 'widgets/nanb_button.dart';
import 'widgets/onb_shell.dart';

/// Translated from `ScreenWelcome` in the design source.
///
/// Two modes:
///  - **Fresh** (no session on disk): Create account / restore / link — the
///    first-run experience.
///  - **Resume** (a non-destructive sign-out left the session + chat history on
///    disk): a prominent "Continue as @username" that reattaches the same
///    device in one tap, plus a guarded "use a different account" that wipes
///    local state first (so a switch can't re-open the old account's database).
class WelcomeScreen extends ConsumerStatefulWidget {
  const WelcomeScreen({super.key});

  @override
  ConsumerState<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends ConsumerState<WelcomeScreen> {
  /// Cached once so rebuilds (theme, resume spinner) don't re-hit storage.
  /// Resume mode is shown only when BOTH a session is on disk AND the manual
  /// sign-out gate is set — a server-forced sign-out (revoked/deleted device)
  /// leaves the session but no gate, and must NOT offer "Continue" (it would
  /// just reconnect and get re-rejected); that case falls through to restore.
  late final Future<({JwtSession? session, bool signedOut})> _resumeStateFuture =
      _loadResumeState();

  Future<({JwtSession? session, bool signedOut})> _loadResumeState() async {
    final repo = ref.read(sessionRepositoryProvider);
    final session = await repo.current();
    final signedOut = await repo.isSignedOut();
    return (session: session, signedOut: signedOut);
  }

  /// Set after "use a different account" wipes local state — forces the fresh
  /// (create/restore/link) view even though a session was present at entry.
  bool _forceFresh = false;

  /// True while a resume is in flight (re-opening MLS + reconnecting), so the
  /// button reads as busy and isn't tappable twice.
  bool _resuming = false;

  @override
  Widget build(BuildContext context) {
    final t = DesignTokens.of(context);
    final content = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          // Web: a compact block centred in the window; mobile: unchanged
          // (header at the top, actions pinned to the bottom via the Spacer).
          mainAxisSize: kIsWeb ? MainAxisSize.min : MainAxisSize.max,
          children: [
            SizedBox(height: kIsWeb ? 0 : 60),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Chat',
                  style: monoStyle(
                    fontSize: 12,
                    color: t.accent,
                    letterSpacing: 4,
                  ),
                ),
                IconButton(
                  onPressed: () => context.push(Routes.settingsNetwork),
                  icon: Icon(Icons.dns_outlined, size: 18, color: t.textMuted),
                  tooltip: 'Server settings',
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
              ],
            ),
            const SizedBox(height: 24),
            Text(
              'Messages that\nonly you can read.',
              style: TextStyle(
                fontSize: 36,
                fontWeight: FontWeight.w500,
                height: 1.1,
                letterSpacing: -0.5,
                color: t.text,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'End-to-end encrypted chat. No phone number, '
              'no email — just a username you choose.',
              style: TextStyle(
                fontSize: 15,
                color: t.textMuted,
                height: 1.5,
              ),
            ),
            kIsWeb ? const SizedBox(height: 40) : const Spacer(),
            FutureBuilder<({JwtSession? session, bool signedOut})>(
              future: _resumeStateFuture,
              builder: (context, snap) {
                final data = snap.data;
                // Until the load settles, render the fresh actions (the common
                // first-run case) so the screen never flashes empty.
                if (!_forceFresh &&
                    snap.connectionState == ConnectionState.done &&
                    data != null &&
                    data.signedOut &&
                    data.session != null) {
                  return _resumeActions(t, data.session!);
                }
                return _freshActions(t);
              },
            ),
            const SizedBox(height: 24),
            _CryptoBadge(t: t),
            const SizedBox(height: 12),
          ],
    );
    return Scaffold(
      body: OnbShell(
        hideBar: true,
        child: kIsWeb
            ? Center(child: SingleChildScrollView(child: content))
            : content,
      ),
    );
  }

  /// Resume view — a kept session is on disk after a non-destructive sign-out.
  Widget _resumeActions(DesignTokens t, JwtSession session) {
    final handle = session.username.startsWith('@')
        ? session.username
        : '@${session.username}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        NanbButton(
          label: _resuming ? 'Resuming…' : 'Continue as $handle',
          kind: NanbButtonKind.primary,
          fullWidth: true,
          onPressed: _resuming ? null : () => _resume(handle),
        ),
        const SizedBox(height: 10),
        TextButton(
          onPressed: _resuming ? null : _useDifferentAccount,
          child: Text(
            'Use a different account',
            style: monoStyle(
              fontSize: 11.5,
              color: t.textMuted,
              letterSpacing: 0.3,
            ),
          ),
        ),
      ],
    );
  }

  /// Fresh view — first run, or after the user erased to switch accounts.
  Widget _freshActions(DesignTokens t) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        NanbButton(
          label: 'Create account',
          kind: NanbButtonKind.primary,
          fullWidth: true,
          onPressed: () => context.push(Routes.username),
        ),
        const SizedBox(height: 12),
        NanbButton(
          label: 'I have a recovery phrase',
          kind: NanbButtonKind.secondary,
          fullWidth: true,
          onPressed: () => context.push(Routes.restore),
        ),
        const SizedBox(height: 10),
        TextButton(
          onPressed: () => context.push(Routes.linkNewDevice),
          child: Text(
            'Link this device to an existing account',
            style: monoStyle(
              fontSize: 11.5,
              color: t.textMuted,
              letterSpacing: 0.3,
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _resume(String handle) async {
    // Require an unlock before reattaching the kept session. Shown as a raw
    // Navigator page (not a go_router route) so the manual-sign-out redirect
    // doesn't bounce it back to /welcome. Backing out leaves the user on the
    // welcome screen, still signed out.
    final authed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => ResumeAuthScreen(handle: handle),
      ),
    );
    if (authed != true || !mounted) return;
    setState(() => _resuming = true);
    try {
      await ref.read(conversationsProvider).resumeAfterSignOut();
    } catch (_) {
      // Best-effort: even if the reconnect fails (offline), the gate is cleared
      // and the chat list keeps its cached conversations + retries in the
      // background. Land the user there rather than stranding them on welcome.
    }
    if (mounted) context.go(Routes.chatList);
  }

  Future<void> _useDifferentAccount() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Use a different account?'),
        content: const Text(
          'This permanently clears the signed-out account\'s chat history, '
          'messages, and keys from this device so another account can sign in. '
          'The account itself stays on the server — you can restore it later '
          'with its recovery phrase.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await wipeLocalAccountState(ref);
    if (mounted) setState(() => _forceFresh = true);
  }
}

class _CryptoBadge extends StatelessWidget {
  const _CryptoBadge({required this.t});
  final DesignTokens t;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: t.surfaceAlt,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: t.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(Icons.lock_outline, size: 14, color: t.accent),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text.rich(
              TextSpan(
                style: monoStyle(
                  fontSize: 10.5,
                  color: t.textMuted,
                  letterSpacing: 0.3,
                ).copyWith(height: 1.5),
                children: [
                  // "via Orbot": the app routes over Tor when the OS provides a
                  // proxy (Orbot) — it doesn't bundle a SOCKS proxy itself, so
                  // "Tor-ready" would overclaim. See Settings → Network.
                  // A browser cannot use Tor at all, so web makes no Tor claim.
                  TextSpan(
                    text: kIsWeb
                        ? 'MLS · Ed25519\n'
                        : 'MLS · Ed25519 · Tor via Orbot\n',
                  ),
                  const TextSpan(text: 'keys generated on this device'),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
