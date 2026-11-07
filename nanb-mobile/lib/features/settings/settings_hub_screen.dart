import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../app/design_tokens.dart';
import '../../app/providers.dart';
import '../../app/router.dart';
import '../../app/theme.dart';
import '../../core/models/api_error.dart';
import '../chat/contact_link_payload.dart';
import '../chat/widgets/avatar_image.dart';
import '../onboarding/local_account_wipe.dart';

/// Translated from `SettingsHubScreen` — identity card + grouped sections.
class SettingsHubScreen extends ConsumerWidget {
  const SettingsHubScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = DesignTokens.of(context);
    // Live count of blocked (incl. rejected) contacts — watched so it updates
    // when one is blocked/unblocked. Was hardcoded to '0'.
    final blockedCount = ref
        .watch(conversationsProvider)
        .conversations
        .where((c) => c.blocked)
        .length;
    return Scaffold(
      backgroundColor: t.bg,
      body: SafeArea(
        child: Column(
          children: [
            _SettingsTopBar(t: t),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.only(bottom: 24),
                children: [
                  _IdentityCard(t: t),
                  _SectionHeader(t: t, label: 'Account'),
                  _Card(
                    t: t,
                    children: [
                      _SettingsRow(
                        t: t,
                        icon: Icons.vpn_key_outlined,
                        label: 'Recovery phrase',
                        sub: 'reveal · re-export',
                        onTap: () => context.push(Routes.settingsRecoveryPhrase),
                      ),
                      _SettingsRow(
                        t: t,
                        icon: Icons.devices_other_outlined,
                        label: 'Linked devices',
                        sub: 'see · authorize · revoke',
                        onTap: () => context.push(Routes.settingsLinkedDevices),
                      ),
                      _SettingsRow(
                        t: t,
                        icon: Icons.logout,
                        label: 'Sign out',
                        sub: 'keep chats on this device · resume anytime',
                        onTap: _confirmSignOut(context, ref),
                      ),
                      _SettingsRow(
                        t: t,
                        icon: Icons.phonelink_erase_outlined,
                        label: 'Erase this device',
                        sub: 'wipe chats + keys here · account stays on server',
                        onTap: _confirmEraseDevice(context, ref),
                      ),
                      _SettingsRow(
                        t: t,
                        icon: Icons.delete_outline,
                        label: 'Delete account',
                        danger: true,
                        last: true,
                        onTap: _confirmDelete(context, ref, t),
                      ),
                    ],
                  ),
                  _SectionHeader(t: t, label: 'Privacy & security'),
                  _Card(
                    t: t,
                    children: [
                      _SettingsRow(
                        t: t,
                        icon: Icons.shield_outlined,
                        label: 'Privacy',
                        sub: 'biometric · disappearing · screenshots',
                        onTap: () => context.push(Routes.settingsPrivacy),
                      ),
                      _SettingsRow(
                        t: t,
                        icon: Icons.block_outlined,
                        label: 'Blocked',
                        right: blockedCount > 0 ? '$blockedCount' : null,
                        onTap: () => context.push(Routes.settingsBlocks),
                      ),
                      _SettingsRow(
                        t: t,
                        icon: Icons.notifications_outlined,
                        label: 'Notifications',
                        onTap: () => context.push(Routes.settingsNotifications),
                      ),
                      _SettingsRow(
                        t: t,
                        icon: Icons.public,
                        label: 'Network',
                        sub: 'connected · clearnet',
                        last: true,
                        onTap: () => context.push(Routes.settingsNetwork),
                      ),
                    ],
                  ),
                  _SectionHeader(t: t, label: 'App'),
                  _Card(
                    t: t,
                    children: [
                      _SettingsRow(
                        t: t,
                        icon: Icons.palette_outlined,
                        label: 'Appearance',
                        right: 'System',
                        onTap: () => context.push(Routes.settingsAppearance),
                      ),
                      _SettingsRow(
                        t: t,
                        icon: Icons.info_outline,
                        label: 'About',
                        sub: 'v0.2.0 · nanb-server v0.3',
                        last: true,
                        onTap: () => context.push(Routes.settingsAbout),
                      ),
                    ],
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 20, 14, 0),
                    child: Text.rich(
                      TextSpan(
                        style: monoStyle(
                          fontSize: 10,
                          color: t.textFaint,
                          letterSpacing: 0.4,
                        ).copyWith(height: 1.6),
                        children: const [
                          TextSpan(text: 'MLS RFC 9420 · CoreCrypto by Wire'),
                        ],
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Sign out = NON-DESTRUCTIVE. Tears down the live session and routes to
  /// /welcome, but leaves chat history, keys, the device identity, and the
  /// session record on disk. Signing back in (the "Continue as @…" button on
  /// /welcome) reattaches the SAME device with conversations intact — messages
  /// only disappear on the user's own Privacy → disappearing schedule. For a
  /// real wipe, see [_confirmEraseDevice]; to remove the server account, see
  /// [_confirmDelete].
  VoidCallback _confirmSignOut(BuildContext context, WidgetRef ref) {
    return () async {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Sign out?'),
          content: const Text(
            'You\'ll be signed out on this device, but your chats and keys '
            'stay here — sign back in with one tap and your conversations are '
            'right where you left them.\n\n'
            'Messages still disappear on the schedule you set under Privacy. '
            'To wipe everything from this phone instead, use "Erase this '
            'device".',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton.tonal(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Sign out'),
            ),
          ],
        ),
      );
      if (confirmed != true || !context.mounted) return;
      // Deregister this device's push token while the JWT still works, so wake
      // notifications stop reaching this phone while signed out. Best-effort —
      // offline sign-out still proceeds; connect() re-registers on resume.
      try {
        await ref.read(apiClientProvider).deletePushToken();
      } catch (_) {/* offline / already gone */}
      // Non-destructive: disconnect + raise the manual-sign-out gate. Nothing
      // on disk is touched. The gate's notifyListeners() also drives the router
      // to /welcome; the explicit go below is belt-and-suspenders.
      await ref.read(conversationsProvider).signOutKeepingData();
      if (context.mounted) {
        context.go(Routes.welcome);
      }
    };
  }

  /// Erase this device = LOCAL wipe only (chat history, identity keys,
  /// ratchet/MLS state, session) so a different account can be created or
  /// restored here. The server account is untouched — unlike delete-account,
  /// no server call is made. Identity keys are phrase-derived, so restoring
  /// with the recovery phrase brings the same identity back (on a fresh device
  /// id).
  ///
  /// Note: this device's registration stays listed under Linked devices (the
  /// server rejects self-revoke); a later restore registers a fresh device id,
  /// and the stale row can be revoked from there.
  VoidCallback _confirmEraseDevice(BuildContext context, WidgetRef ref) {
    return () async {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Erase this device?'),
          content: const Text(
            'This wipes your chats, keys, and session from this device so '
            'another account can sign in. Your account stays on the server.\n\n'
            'You will need your recovery phrase to sign back in — without '
            'it this account cannot be recovered.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton.tonal(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Erase'),
            ),
          ],
        ),
      );
      if (confirmed != true || !context.mounted) return;
      // Deregister this device's push token while the JWT still works, so
      // the old account's wake notifications stop reaching this phone.
      // Best-effort — offline erase still proceeds.
      try {
        await ref.read(apiClientProvider).deletePushToken();
      } catch (_) {/* offline / already gone */}
      // Same wipe chain as delete-account (minus the server deletion) —
      // order matters: tear down conversations + DB file first so the
      // deleted SQLCipher key is harmless on disk by the time we finish.
      await wipeLocalAccountState(ref);
      if (context.mounted) {
        context.go(Routes.welcome);
      }
    };
  }

  VoidCallback _confirmDelete(BuildContext context, WidgetRef ref, DesignTokens t) {
    return () async {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Delete account?'),
          content: const Text(
            'This deletes your account on the server (your username is '
            'reserved for 30 days) and wipes your chat history and keys on '
            'this device. You leave every group, and your chats are deleted '
            'from the devices of everyone you talked to.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton.tonal(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text('Delete', style: TextStyle(color: t.danger)),
            ),
          ],
        ),
      );
      if (confirmed == true && context.mounted) {
        // Tell every 1:1 contact FIRST, while the keys to reach them still
        // exist: their devices delete the chat with this account.
        try {
          await ref.read(conversationsProvider).notifyContactsOfAccountDeletion();
        } catch (_) {/* best-effort — deletion must still proceed */}
        if (!context.mounted) return;
        // Leave every group BEFORE the account is deleted: removal commits
        // are sent with this session's JWT, and the server can't evict us
        // itself (it never sees MLS membership) — skipping this leaves a
        // ghost of the deleted user in everyone else's member list.
        try {
          await ref.read(conversationsProvider).leaveAllGroups();
        } catch (_) {/* best-effort — deletion must still proceed */}
        if (!context.mounted) return;
        // Server-side deletion FIRST, while the JWT still exists — the wipe
        // below destroys it, after which the account could never be deleted
        // remotely. Soft-deletes the account, revokes devices, and starts
        // the 30-day username hold.
        try {
          await ref.read(apiClientProvider).deleteAccount();
        } on ApiError catch (e) {
          // Already gone server-side (e.g. deleted from another device, or a
          // dev-database reset) — local wipe is still the right move.
          if (e.code != 'account_not_found') {
            if (!context.mounted) return;
            final wipeAnyway =
                await _confirmLocalOnlyWipe(context, _deleteFailureReason(e));
            if (wipeAnyway != true) return;
          }
        } catch (e) {
          if (!context.mounted) return;
          final wipeAnyway =
              await _confirmLocalOnlyWipe(context, _deleteFailureReason(e));
          if (wipeAnyway != true) return;
        }
        if (!context.mounted) return;
        // Full wipe — order matters: tear down conversations + DB file first so
        // the deleted SQLCipher key is harmless on disk by the time we finish.
        await wipeLocalAccountState(ref);
        if (context.mounted) {
          context.go(Routes.welcome);
        }
      }
    };
  }

  /// One-line, user-facing reason for a failed server deletion. The raw
  /// error is deliberately not shown — Dio's text dumps RequestOptions
  /// internals and links at the user.
  String _deleteFailureReason(Object error) {
    if (error is ApiError) {
      if (error.statusCode == 401) {
        return "The server rejected this device's session — your sign-in "
            'may have expired.';
      }
      if (error.statusCode != null) {
        return 'The server returned an error (${error.code}, '
            'HTTP ${error.statusCode}).';
      }
    }
    return 'The server could not be reached.';
  }

  /// Server deletion failed — let the user choose between aborting (so they
  /// can retry with connectivity) and wiping this device anyway, knowing the
  /// account lives on server-side until it can be deleted from a restored
  /// session.
  Future<bool?> _confirmLocalOnlyWipe(BuildContext context, String reason) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Server deletion failed'),
        content: Text(
          '$reason\n\n'
          'Wipe this device anyway? Your account will still exist on the '
          'server — you would need to restore with your recovery phrase '
          'later to delete it.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Wipe anyway'),
          ),
        ],
      ),
    );
  }
}

class _SettingsTopBar extends StatelessWidget {
  const _SettingsTopBar({required this.t});
  final DesignTokens t;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
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
          const SizedBox(width: 8),
          Text(
            'SETTINGS',
            style: monoStyle(
              fontSize: 11,
              color: t.textMuted,
              letterSpacing: 2,
            ),
          ),
        ],
      ),
    );
  }
}

/// Username + short identity-key fingerprint + contact-QR payload for the
/// identity card. autoDispose so a delete-account wipe doesn't serve a
/// stale identity to the next session on this device.
final _identityCardDataProvider = FutureProvider.autoDispose<
    ({String username, String fingerprint, String? qrPayload})>((ref) async {
  final session = await ref.watch(sessionRepositoryProvider).current();
  final identity = await ref.watch(cryptoBridgeProvider).currentIdentity();
  // First 6 bytes of the Ed25519 identity pub key as 3 hex groups — same
  // format as the linked-devices screen.
  final hex = (identity?.publicKey ?? const <int>[])
      .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
      .join();
  final pairs = <String>[];
  for (var i = 0; i + 4 <= hex.length && pairs.length < 3; i += 4) {
    pairs.add(hex.substring(i, i + 4));
  }
  final qrPayload = (session != null && identity != null)
      ? ContactLinkPayload(
          username: session.username,
          publicKey: identity.publicKey,
        ).encode()
      : null;
  return (
    username: session != null ? '@${session.username}' : '@…',
    fingerprint: pairs.isEmpty ? '— — — — —' : pairs.join(' '),
    qrPayload: qrPayload,
  );
});

/// Fast path for the identity card's @handle. Reads only the session (served
/// from SessionRepository's in-memory cache after first load), so the username
/// paints on the first frame instead of waiting on the native identity-key
/// fetch that [_identityCardDataProvider] also awaits for the fingerprint + QR.
final _identityUsernameProvider = FutureProvider.autoDispose<String?>((ref) async {
  final session = await ref.watch(sessionRepositoryProvider).current();
  return session != null ? '@${session.username}' : null;
});

class _IdentityCard extends ConsumerWidget {
  const _IdentityCard({required this.t});
  final DesignTokens t;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(_identityCardDataProvider).valueOrNull;
    final displayName = ref.watch(myDisplayNameProvider).valueOrNull;
    final avatar = ref.watch(myAvatarProvider).valueOrNull;
    // Fast provider paints the handle immediately; fall back to the full
    // card-data provider's copy (then the placeholder) until it resolves.
    final username =
        ref.watch(_identityUsernameProvider).valueOrNull ?? data?.username ?? '@…';
    final fingerprint = data?.fingerprint ?? '— — — — —';
    final qrPayload = data?.qrPayload;
    // Primary line = display name when set, else the @username.
    final primary = displayName ?? username;
    final secondary = displayName != null
        ? '$username · key $fingerprint'
        : 'nanb.link · key $fingerprint';
    return Container(
      margin: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: t.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => context.push(Routes.settingsEditProfile),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              AvatarImage(name: primary, descriptor: avatar, size: 48),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      primary,
                      style: displayName != null
                          ? TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w500,
                              color: t.text)
                          : monoStyle(fontSize: 14, color: t.text),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      secondary,
                      style: monoStyle(
                        fontSize: 10,
                        color: t.textMuted,
                        letterSpacing: 0.3,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.edit_outlined, size: 16, color: t.textFaint),
              const SizedBox(width: 4),
              IconButton(
                icon: Icon(Icons.qr_code, size: 20, color: t.textMuted),
                padding: const EdgeInsets.all(4),
                constraints: const BoxConstraints(),
                onPressed: qrPayload == null
                    ? null
                    : () => _showIdentityQr(
                        context, t, username, fingerprint, qrPayload),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Bottom sheet with the contact QR (`nanb-link://contact?...`) a peer
  /// will scan to add this user with the identity key pre-verified.
  void _showIdentityQr(
    BuildContext context,
    DesignTokens t,
    String username,
    String fingerprint,
    String payload,
  ) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: t.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(username, style: monoStyle(fontSize: 14, color: t.text)),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8),
              ),
              child: QrImageView(
                data: payload,
                version: QrVersions.auto,
                size: 200,
                backgroundColor: Colors.white,
              ),
            ),
            const SizedBox(height: 14),
            Text(
              'IDENTITY KEY',
              style: monoStyle(
                fontSize: 10,
                color: t.textFaint,
                letterSpacing: 0.4,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              fingerprint,
              style:
                  monoStyle(fontSize: 12, color: t.text, letterSpacing: 0.5),
            ),
            const SizedBox(height: 12),
            Text(
              'Someone can scan this to add you and verify your key '
              'in one step.',
              textAlign: TextAlign.center,
              style: TextStyle(color: t.textMuted, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.t, required this.label});
  final DesignTokens t;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 20, 14, 8),
      child: Text(
        label.toUpperCase(),
        style: monoStyle(
          fontSize: 10,
          color: t.textFaint,
          letterSpacing: 1,
        ),
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.t, required this.children});
  final DesignTokens t;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: t.border),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Column(children: children),
      ),
    );
  }
}

class _SettingsRow extends StatelessWidget {
  const _SettingsRow({
    required this.t,
    required this.icon,
    required this.label,
    this.sub,
    this.right,
    this.danger = false,
    this.last = false,
    this.onTap,
  });

  final DesignTokens t;
  final IconData icon;
  final String label;
  final String? sub;
  final String? right;
  final bool danger;
  final bool last;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        decoration: BoxDecoration(
          border: last
              ? null
              : Border(bottom: BorderSide(color: t.border)),
        ),
        child: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: t.surfaceAlt,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: t.border),
              ),
              child: Icon(icon, size: 16, color: danger ? t.danger : t.text),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 14,
                      color: danger ? t.danger : t.text,
                    ),
                  ),
                  if (sub != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      sub!,
                      style: monoStyle(
                        fontSize: 10,
                        color: t.textMuted,
                        letterSpacing: 0.3,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (right != null) ...[
              Text(
                right!,
                style: monoStyle(
                  fontSize: 11,
                  color: t.textMuted,
                  letterSpacing: 0.3,
                ),
              ),
              const SizedBox(width: 8),
            ],
            Icon(Icons.chevron_right, size: 16, color: t.textFaint),
          ],
        ),
      ),
    );
  }
}
