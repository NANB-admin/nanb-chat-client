import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/design_tokens.dart';
import '../../app/providers.dart';
import '../../app/router.dart';
import '../../app/theme.dart';
import '../../core/models/api_error.dart';
import '../onboarding/widgets/nanb_button.dart';
import 'contact_link_payload.dart';

/// Translated from the design's `NewChatScreen`. Username search → match card
/// → "Start chat" creates the conversation and navigates to the thread.
class NewChatScreen extends ConsumerStatefulWidget {
  const NewChatScreen({super.key});

  @override
  ConsumerState<NewChatScreen> createState() => _NewChatScreenState();
}

class _NewChatScreenState extends ConsumerState<NewChatScreen> {
  final _input = TextEditingController();
  String _searchedUsername = '';
  bool _searching = false;
  bool _starting = false;
  String? _matchUsername;
  List<int>? _matchPubKey;
  String? _matchAccountId;

  /// True when the match came from a scanned/pasted contact QR whose key
  /// matched the server's record — the conversation starts pre-verified.
  bool _keyVerified = false;
  String? _error;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  void _resetMatch() {
    _error = null;
    _matchUsername = null;
    _matchPubKey = null;
    _matchAccountId = null;
    _keyVerified = false;
  }

  Future<void> _search() async {
    final raw = _input.text.trim();
    // A pasted contact link (the QR's payload) routes through the same
    // verification path as a camera scan.
    if (raw.startsWith('nanb-link://')) {
      try {
        await _applyContactPayload(ContactLinkPayload.parse(raw));
      } on FormatException catch (e) {
        setState(() {
          _resetMatch();
          _error = "That link isn't a valid nanb contact code (${e.message}).";
        });
      }
      return;
    }
    final cleaned = (raw.startsWith('@') ? raw.substring(1) : raw).toLowerCase();
    if (cleaned.isEmpty) return;
    setState(() {
      _searching = true;
      _searchedUsername = cleaned;
      _resetMatch();
    });
    try {
      final account = await ref.read(apiClientProvider).lookupAccount(cleaned);
      if (!mounted) return;
      setState(() {
        _matchUsername = account.username;
        _matchPubKey = account.identityPubKey;
        _matchAccountId = account.accountId;
      });
    } on ApiError catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.code == 'account_not_found'
            ? 'No account with that handle.'
            : e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  Future<void> _scanQr() async {
    final payload =
        await context.push<ContactLinkPayload>(Routes.scanContact);
    if (payload == null || !mounted) return;
    _input.text = '@${payload.username}';
    await _applyContactPayload(payload);
  }

  /// Resolves a scanned/pasted contact payload: looks the username up on
  /// the server and cross-checks the identity key. Match → pre-verified
  /// contact card. Mismatch → hard warning, no start button (someone is
  /// lying — the server, the QR, or a man in the middle).
  Future<void> _applyContactPayload(ContactLinkPayload payload) async {
    final session = await ref.read(sessionRepositoryProvider).current();
    if (!mounted) return;
    if (session != null && session.username.toLowerCase() == payload.username.toLowerCase()) {
      setState(() {
        _resetMatch();
        _searchedUsername = payload.username;
        _error = "That's your own contact code.";
      });
      return;
    }
    setState(() {
      _searching = true;
      _searchedUsername = payload.username;
      _resetMatch();
    });
    try {
      final account =
          await ref.read(apiClientProvider).lookupAccount(payload.username);
      if (!mounted) return;
      if (!_bytesEqual(account.identityPubKey, payload.publicKey)) {
        setState(() {
          _error = 'KEY MISMATCH for @${payload.username}: the QR and the '
              'server disagree about their identity key. Do not start this '
              'chat — verify with them in person.';
        });
        return;
      }
      setState(() {
        _matchUsername = account.username;
        _matchPubKey = account.identityPubKey;
        _matchAccountId = account.accountId;
        _keyVerified = true;
      });
    } on ApiError catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.code == 'account_not_found'
            ? 'No account with that handle on this server.'
            : e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  static bool _bytesEqual(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  Future<void> _startChat() async {
    final username = _matchUsername;
    if (username == null || _starting) return;
    setState(() => _starting = true);
    try {
      final session = await ref.read(sessionRepositoryProvider).current();
      if (session == null) throw StateError('No session');
      final notifier = ref.read(conversationsProvider);
      final convoId = await notifier.startConversation(
          myDeviceId: session.deviceId, username: username);
      // QR-sourced contacts whose key matched the server are verified by
      // construction — the user got the key out-of-band.
      if (_keyVerified) {
        await notifier.setVerified(convoId, true);
      }
      if (!mounted) return;
      context.go(Routes.chat.replaceFirst(':conversationId', convoId));
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = DesignTokens.of(context);
    return Scaffold(
      backgroundColor: t.bg,
      body: SafeArea(
        child: Column(
          children: [
            _SearchBar(t: t, controller: _input, onSubmit: _search, busy: _searching),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'MATCH',
                      style: monoStyle(
                        fontSize: 10,
                        color: t.textFaint,
                        letterSpacing: 1,
                      ),
                    ),
                    const SizedBox(height: 8),
                    if (_error != null)
                      _ErrorBox(t: t, message: _error!)
                    else if (_matchUsername != null)
                      _MatchCard(
                        t: t,
                        username: _matchUsername!,
                        pubKey: _matchPubKey ?? const [],
                        accountId: _matchAccountId ?? '',
                        keyVerified: _keyVerified,
                        starting: _starting,
                        onStart: _startChat,
                      )
                    else if (_searchedUsername.isEmpty)
                      _Hint(t: t)
                    else
                      _Hint(t: t),
                    const SizedBox(height: 24),
                    _OtherWaysCard(t: t, onScan: _scanQr),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SearchBar extends StatelessWidget {
  const _SearchBar({
    required this.t,
    required this.controller,
    required this.onSubmit,
    required this.busy,
  });

  final DesignTokens t;
  final TextEditingController controller;
  final VoidCallback onSubmit;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      decoration: BoxDecoration(
        color: t.surface,
        border: Border(bottom: BorderSide(color: t.border)),
      ),
      child: Row(
        children: [
          IconButton(
            icon: Icon(Icons.arrow_back, color: t.text),
            iconSize: 22,
            padding: const EdgeInsets.all(4),
            constraints: const BoxConstraints(),
            onPressed: () => Navigator.of(context).maybePop(),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                color: t.surfaceAlt,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: t.border),
              ),
              child: Row(
                children: [
                  Icon(Icons.search, size: 14, color: t.textMuted),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: controller,
                      autofocus: true,
                      onSubmitted: (_) => onSubmit(),
                      decoration: InputDecoration(
                        hintText: '@handle',
                        hintStyle: monoStyle(fontSize: 13, color: t.textFaint),
                        border: InputBorder.none,
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(vertical: 10),
                      ),
                      style: monoStyle(fontSize: 13, color: t.text),
                    ),
                  ),
                  // Explicit, tappable affordance — the search also fires on
                  // the keyboard's submit, but a visible button makes it clear
                  // how to look someone up.
                  busy
                      ? Text(
                          'SEARCHING…',
                          style: monoStyle(fontSize: 10, color: t.textFaint),
                        )
                      : GestureDetector(
                          onTap: onSubmit,
                          behavior: HitTestBehavior.opaque,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 7),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(color: t.accent),
                            ),
                            child: Text(
                              'SEARCH',
                              style: monoStyle(
                                fontSize: 10,
                                color: t.accent,
                                letterSpacing: 0.5,
                              ),
                            ),
                          ),
                        ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MatchCard extends StatelessWidget {
  const _MatchCard({
    required this.t,
    required this.username,
    required this.pubKey,
    required this.accountId,
    required this.keyVerified,
    required this.starting,
    required this.onStart,
  });
  final DesignTokens t;
  final String username;
  final List<int> pubKey;
  final String accountId;

  /// Key came from a scanned QR and matched the server — show the shield.
  final bool keyVerified;
  final bool starting;
  final VoidCallback onStart;

  String _fingerprint() {
    if (pubKey.length < 6) return '— — —';
    final hex = pubKey.take(6).map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase()).join();
    final pairs = <String>[];
    for (var i = 0; i < hex.length; i += 4) {
      pairs.add(hex.substring(i, (i + 4).clamp(0, hex.length)));
    }
    return pairs.join(' ');
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: t.border),
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: t.surfaceAlt,
              borderRadius: BorderRadius.circular(22),
            ),
            child: Text(
              username.replaceAll('@', '').substring(0, 1).toUpperCase(),
              style: monoStyle(fontSize: 16, color: t.text),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        '@$username',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: monoStyle(fontSize: 14, color: t.text),
                      ),
                    ),
                    if (keyVerified) ...[
                      const SizedBox(width: 6),
                      Icon(Icons.shield_outlined, size: 13, color: t.accent),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  keyVerified
                      ? 'key ${_fingerprint()} · verified via QR'
                      : 'nanb.link · key ${_fingerprint()}',
                  style: monoStyle(
                    fontSize: 10,
                    color: keyVerified ? t.accent : t.textMuted,
                    letterSpacing: 0.3,
                  ),
                ),
              ],
            ),
          ),
          NanbButton(
            label: starting ? 'Starting…' : 'Start chat',
            onPressed: starting ? null : onStart,
          ),
        ],
      ),
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint({required this.t});
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
      child: Text(
        'Type the exact @handle to find someone. We don\'t fuzzy-search and we don\'t index your contacts.',
        style: TextStyle(fontSize: 12, color: t.textMuted, height: 1.5),
      ),
    );
  }
}

class _ErrorBox extends StatelessWidget {
  const _ErrorBox({required this.t, required this.message});
  final DesignTokens t;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: t.danger.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: t.danger),
      ),
      child: Text(
        message,
        style: monoStyle(fontSize: 11, color: t.danger),
      ),
    );
  }
}

class _OtherWaysCard extends StatelessWidget {
  const _OtherWaysCard({required this.t, required this.onScan});
  final DesignTokens t;
  final VoidCallback onScan;

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
            'OTHER WAYS TO ADD',
            style: monoStyle(
              fontSize: 10,
              color: t.textFaint,
              letterSpacing: 1,
            ),
          ),
          const SizedBox(height: 10),
          NanbButton(
            label: 'Scan contact QR',
            kind: NanbButtonKind.secondary,
            icon: Icons.qr_code_scanner,
            fullWidth: true,
            onPressed: onScan,
          ),
          const SizedBox(height: 10),
          Text(
            'Scan the QR on their settings screen — or paste their '
            'nanb-link:// code into the search box. Either way their '
            'encryption key is verified in the same step.',
            style: TextStyle(fontSize: 12, color: t.textMuted, height: 1.5),
          ),
        ],
      ),
    );
  }
}
