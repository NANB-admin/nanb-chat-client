import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/design_tokens.dart';
import '../../app/providers.dart';
import '../../app/router.dart';
import '../../app/theme.dart';
import '../../core/platform/ephemeral_clipboard.dart';
import 'media_pipeline.dart';
import 'safety_number.dart';
import 'widgets/avatar_image.dart';
import 'widgets/chat_background_sheet.dart';
import 'widgets/disappearing_picker.dart';
import 'widgets/report_sheet.dart';

/// Translated from `ContactProfileScreen` in the design source. Reads the
/// conversation by id; renders avatar + username + 60-digit safety number
/// derived from the local + peer identity public keys.
class ContactProfileScreen extends ConsumerStatefulWidget {
  const ContactProfileScreen({super.key, required this.conversationId});
  final String conversationId;

  @override
  ConsumerState<ContactProfileScreen> createState() =>
      _ContactProfileScreenState();
}

class _ContactProfileScreenState extends ConsumerState<ContactProfileScreen> {
  String? _safetyNumber;

  @override
  void initState() {
    super.initState();
    Future.microtask(_loadSafetyNumber);
    // Pull the peer's latest profile (display name + avatar) so the photo shows
    // even when the contact card is the first thing opened for this peer. This
    // also backfills a missing identity key, so recompute the safety number
    // afterwards — otherwise a key-less 1:1 would show a blank number forever.
    Future.microtask(() async {
      await ref
          .read(conversationsProvider)
          .refreshPeerProfile(widget.conversationId);
      if (mounted) await _loadSafetyNumber();
    });
  }

  Future<void> _loadSafetyNumber() async {
    final convo = ref.read(conversationsProvider).byId(widget.conversationId);
    if (convo == null) return;
    final myIdentity = await ref.read(cryptoBridgeProvider).currentIdentity();
    final peerKey = convo.peerIdentityPubKey;
    final mineKey = myIdentity?.publicKey ?? const <int>[];
    final number = await SafetyNumber.compute(mineKey: mineKey, peerKey: peerKey);
    if (!mounted) return;
    setState(() => _safetyNumber = number);
  }

  /// Unblock immediately; blocking asks first (it hides the thread and stops
  /// messages). Local-only — the peer is never told.
  Future<void> _confirmToggleBlock() async {
    final notifier = ref.read(conversationsProvider);
    final convo = notifier.byId(widget.conversationId);
    if (convo == null) return;
    if (convo.blocked) {
      await notifier.setBlocked(widget.conversationId, false);
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Block ${convo.peerUsername}?'),
        content: const Text(
          "You won't receive their messages or notifications, and the "
          'conversation is hidden. They are not told. You can unblock anytime '
          'from Settings → Blocked.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Block'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await notifier.setBlocked(widget.conversationId, true);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${convo.peerUsername} blocked')),
      );
    }
  }

  /// Reports this contact: opens the report sheet (reason + optional note +
  /// "also block"), forwards the peer's recent messages to the server for
  /// review, and blocks them unless the user opted out.
  Future<void> _confirmReport() async {
    final notifier = ref.read(conversationsProvider);
    final convo = notifier.byId(widget.conversationId);
    if (convo == null) return;
    final draft = await showReportSheet(context, peerUsername: convo.peerUsername);
    if (draft == null) return;
    try {
      await notifier.reportUser(
        widget.conversationId,
        reason: draft.reason,
        note: draft.note,
        alsoBlock: draft.alsoBlock,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(draft.alsoBlock
                ? 'Report submitted · ${convo.peerUsername} blocked'
                : 'Report submitted'),
          ),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Couldn't submit report. Try again.")),
        );
      }
    }
  }

  /// Wipes this chat's local message history (keeps the contact). Asks first —
  /// it can't be undone and the peer keeps their copy.
  Future<void> _confirmClearHistory() async {
    final notifier = ref.read(conversationsProvider);
    final convo = notifier.byId(widget.conversationId);
    if (convo == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear chat history?'),
        content: const Text(
          'This deletes every message in this chat on this device. The contact '
          'stays and the other person keeps their copy. This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await notifier.clearMessages(widget.conversationId);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Chat history cleared')),
      );
    }
  }

  /// Opens the per-contact disappearing-messages picker and persists the choice.
  Future<void> _editDisappearing() async {
    final notifier = ref.read(conversationsProvider);
    final convo = notifier.byId(widget.conversationId);
    if (convo == null) return;
    final chosen = await showDisappearingPicker(
      context,
      current: convo.disappearingTtl,
    );
    if (chosen == null) return;
    await notifier.setDisappearingTtl(widget.conversationId, chosen);
  }

  @override
  Widget build(BuildContext context) {
    final t = DesignTokens.of(context);
    final notifier = ref.watch(conversationsProvider);
    final convo = notifier.byId(widget.conversationId);
    final verified = convo?.verified ?? false;
    final avatar = convo == null ? null : notifier.peerAvatarDescriptor(convo);

    return Scaffold(
      backgroundColor: t.bg,
      body: SafeArea(
        child: Column(
          children: [
            _TopBar(
              t: t,
              title: 'Contact',
              menu: convo == null
                  ? null
                  : PopupMenuButton<String>(
                      icon: Icon(Icons.more_vert, color: t.textMuted, size: 20),
                      onSelected: (v) {
                        switch (v) {
                          case 'background':
                            showChatBackgroundSheet(context, widget.conversationId);
                          case 'clear':
                            _confirmClearHistory();
                          case 'report':
                            _confirmReport();
                          case 'block':
                            _confirmToggleBlock();
                        }
                      },
                      itemBuilder: (_) => [
                        const PopupMenuItem(
                          value: 'background',
                          child: Text('Chat background'),
                        ),
                        const PopupMenuItem(
                          value: 'clear',
                          child: Text('Clear chat history'),
                        ),
                        const PopupMenuItem(
                          value: 'report',
                          child: Text('Report'),
                        ),
                        PopupMenuItem(
                          value: 'block',
                          child: Text(convo.blocked ? 'Unblock' : 'Block'),
                        ),
                      ],
                    ),
            ),
            Expanded(
              child: convo == null
                  ? Center(
                      child: Text('Conversation not found', style: TextStyle(color: t.textMuted)),
                    )
                  : ListView(
                      children: [
                        _ProfileHeader(
                          t: t,
                          username: convo.peerUsername,
                          verified: verified,
                          avatar: avatar,
                        ),
                        _SafetySection(
                          t: t,
                          safetyNumber: _safetyNumber,
                          verified: verified,
                          onMarkVerified: () => notifier.setVerified(widget.conversationId, true),
                        ),
                        _SettingsSection(
                          t: t,
                          blocked: convo.blocked,
                          muted: convo.muted,
                          disappearingTtl: convo.disappearingTtl,
                          onToggleBlock: _confirmToggleBlock,
                          onToggleMute: () => notifier.setMuted(
                              widget.conversationId, !convo.muted),
                          onDisappearing: _editDisappearing,
                          onReport: _confirmReport,
                          onSharedMedia: () => context.push(Routes.sharedMedia
                              .replaceFirst(
                                  ':conversationId', widget.conversationId)),
                        ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({required this.t, required this.title, this.menu});
  final DesignTokens t;
  final String title;
  final Widget? menu;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
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
          Expanded(
            child: Text(
              title,
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: t.text),
            ),
          ),
          menu ?? const SizedBox(width: 36),
        ],
      ),
    );
  }
}

class _ProfileHeader extends StatelessWidget {
  const _ProfileHeader({
    required this.t,
    required this.username,
    required this.verified,
    this.avatar,
  });
  final DesignTokens t;
  final String username;
  final bool verified;
  final MediaDescriptor? avatar;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 16),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: t.border)),
      ),
      child: Column(
        children: [
          AvatarImage(
            name: username,
            descriptor: avatar,
            size: 80,
            enlargeOnTap: true,
          ),
          const SizedBox(height: 12),
          Text(
            username,
            style: monoStyle(fontSize: 16, color: t.text),
          ),
          const SizedBox(height: 4),
          Text(
            'nanb.link',
            style: monoStyle(
              fontSize: 10,
              color: t.textMuted,
              letterSpacing: 0.4,
            ),
          ),
          if (verified) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: t.accent.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: t.accent),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.shield, size: 11, color: t.accent),
                  const SizedBox(width: 6),
                  Text(
                    'VERIFIED',
                    style: monoStyle(
                      fontSize: 10,
                      color: t.accent,
                      letterSpacing: 0.5,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _SafetySection extends StatelessWidget {
  const _SafetySection({
    required this.t,
    required this.safetyNumber,
    required this.verified,
    required this.onMarkVerified,
  });
  final DesignTokens t;
  final String? safetyNumber;
  final bool verified;
  final VoidCallback onMarkVerified;

  @override
  Widget build(BuildContext context) {
    // Three states: null = still loading; '' = key not available yet (can't
    // compute); else = a real 60-digit number.
    final hasNumber = safetyNumber != null && safetyNumber!.isNotEmpty;
    final unavailable = safetyNumber != null && safetyNumber!.isEmpty;
    final groups = hasNumber
        ? SafetyNumber.split(safetyNumber!)
        : List.filled(12, '· · · · ·');
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'SAFETY NUMBER',
            style: monoStyle(
              fontSize: 10,
              color: t.textFaint,
              letterSpacing: 1,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'A unique code for this contact, derived from both your encryption '
            'keys. If it matches on both phones, no one is intercepting or '
            'impersonating them — your chat is genuinely end-to-end encrypted.',
            style: TextStyle(fontSize: 12, color: t.textMuted, height: 1.5),
          ),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: t.surface,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: t.border),
            ),
            child: Column(
              children: [
                _SafetyGrid(t: t, groups: groups),
                const SizedBox(height: 14),
                Container(
                  padding: const EdgeInsets.only(top: 14),
                  decoration: BoxDecoration(
                    border: Border(top: BorderSide(color: t.border)),
                  ),
                  child: Text(
                    unavailable
                        ? "Not available yet — this contact's encryption key hasn't been retrieved. It appears once you've exchanged a message with them."
                        : verified
                            ? 'Verified by you on this device.'
                            : 'Compare these 60 digits with your contact in person, on a video call, or via another trusted channel.',
                    style: TextStyle(fontSize: 12, color: t.textMuted, height: 1.5),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: hasNumber
                            ? () => copyEphemeral(safetyNumber!)
                            : null,
                        icon: const Icon(Icons.copy_outlined, size: 16),
                        label: const Text('Copy'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: t.text,
                          side: BorderSide(color: t.borderStrong),
                          padding: const EdgeInsets.symmetric(vertical: 11),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                        ),
                      ),
                    ),
                  ],
                ),
                if (hasNumber && !verified) ...[
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: onMarkVerified,
                      icon: const Icon(Icons.check, size: 16),
                      label: const Text('MARK AS VERIFIED'),
                      style: FilledButton.styleFrom(
                        backgroundColor: t.accent,
                        foregroundColor: t.accentOn,
                        padding: const EdgeInsets.symmetric(vertical: 11),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                        textStyle: monoStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          letterSpacing: 0.4,
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SafetyGrid extends StatelessWidget {
  const _SafetyGrid({required this.t, required this.groups});
  final DesignTokens t;
  final List<String> groups;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    for (var i = 0; i < groups.length; i += 5) {
      final rowItems = <Widget>[];
      for (var j = 0; j < 5; j++) {
        final idx = i + j;
        rowItems.add(Expanded(
          child: Center(
            child: Text(
              idx < groups.length ? groups[idx] : '',
              style: monoStyle(
                fontSize: 13,
                color: t.text,
                letterSpacing: 1,
              ),
            ),
          ),
        ));
        if (j < 4) rowItems.add(const SizedBox(width: 10));
      }
      rows.add(Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(children: rowItems),
      ));
    }
    return Column(children: rows);
  }
}

class _SettingsSection extends StatelessWidget {
  const _SettingsSection({
    required this.t,
    required this.blocked,
    required this.muted,
    required this.disappearingTtl,
    required this.onToggleBlock,
    required this.onToggleMute,
    required this.onDisappearing,
    required this.onReport,
    required this.onSharedMedia,
  });
  final DesignTokens t;
  final bool blocked;
  final bool muted;
  final int disappearingTtl;
  final VoidCallback onToggleBlock;
  final VoidCallback onToggleMute;
  final VoidCallback onDisappearing;
  final VoidCallback onReport;
  final VoidCallback onSharedMedia;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              'SETTINGS',
              style: monoStyle(
                fontSize: 10,
                color: t.textFaint,
                letterSpacing: 1,
              ),
            ),
          ),
          Container(
            decoration: BoxDecoration(
              color: t.surface,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: t.border),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Column(
                children: [
                  _row(t, Icons.perm_media_outlined, 'Media, links and files',
                      null, false,
                      onTap: onSharedMedia),
                  _row(t, Icons.hourglass_empty, 'Disappearing messages',
                      disappearingLabel(disappearingTtl), false,
                      onTap: onDisappearing),
                  _row(
                    t,
                    muted
                        ? Icons.notifications_off_outlined
                        : Icons.notifications_outlined,
                    'Notifications',
                    muted ? 'Muted' : 'On',
                    false,
                    onTap: onToggleMute,
                  ),
                  _row(
                    t,
                    Icons.flag_outlined,
                    'Report',
                    null,
                    true,
                    onTap: onReport,
                  ),
                  _row(
                    t,
                    blocked ? Icons.block : Icons.block_outlined,
                    blocked ? 'Unblock' : 'Block',
                    null,
                    !blocked,
                    last: true,
                    onTap: onToggleBlock,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _row(DesignTokens t, IconData icon, String label, String? right, bool danger,
      {bool last = false, VoidCallback? onTap}) {
    final color = danger ? t.danger : t.text;
    final row = Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        border: last ? null : Border(bottom: BorderSide(color: t.border)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: danger ? t.danger : t.textMuted),
          const SizedBox(width: 12),
          Expanded(
            child: Text(label, style: TextStyle(fontSize: 14, color: color)),
          ),
          if (right != null) ...[
            Text(
              right,
              style: monoStyle(fontSize: 11, color: t.textMuted),
            ),
            const SizedBox(width: 8),
          ],
          Icon(Icons.chevron_right, size: 14, color: t.textFaint),
        ],
      ),
    );
    if (onTap == null) return row;
    return InkWell(onTap: onTap, child: row);
  }
}
