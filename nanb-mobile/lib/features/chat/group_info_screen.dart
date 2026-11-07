import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/design_tokens.dart';
import '../../app/providers.dart';
import '../../app/router.dart';
import '../../app/theme.dart';
import '../onboarding/widgets/nanb_button.dart';
import 'models/conversation.dart';
import 'models/conversation_kind.dart';
import 'models/group_member.dart';
import 'models/member_seed.dart';
import 'media_pipeline.dart';
import 'services/group_photo_picker.dart';
import 'widgets/avatar_image.dart';
import 'widgets/chat_background_sheet.dart';
import 'widgets/disappearing_picker.dart';
import 'widgets/nanb_avatar.dart';

/// Wired to real [ConversationsNotifier] state. Supports:
/// - Header: groupName, member count, MLS epoch.
/// - Members list: admin badge, self label, long-press remove (admin only).
/// - Add member picker (admin only).
/// - Leave group with confirmation.
class GroupInfoScreen extends ConsumerWidget {
  const GroupInfoScreen({super.key, this.conversationId});
  final String? conversationId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.watch(conversationsProvider);
    final convo = conversationId == null ? null : notifier.byId(conversationId!);
    final t = DesignTokens.of(context);

    if (convo == null || convo.kind != ConversationKind.group) {
      return Scaffold(
        backgroundColor: t.bg,
        body: SafeArea(
          child: Column(
            children: [
              _TopBar(t: t),
              Expanded(
                child: Center(
                  child: Text(
                    'Group not found',
                    style: TextStyle(color: t.textMuted),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    final selfMember = convo.members.firstWhere(
      (m) => m.isSelf,
      orElse: () => GroupMember(
        accountId: '',
        username: '',
        deviceId: '',
        identityPubKey: const [],
        x25519PubKey: const [],
        isAdmin: false,
        isSelf: false,
      ),
    );
    final isSelfAdmin = selfMember.isAdmin;

    return Scaffold(
      backgroundColor: t.bg,
      body: SafeArea(
        child: Column(
          children: [
            _TopBar(
              t: t,
              menu: PopupMenuButton<String>(
                icon: Icon(Icons.more_vert, color: t.textMuted, size: 20),
                onSelected: (v) {
                  switch (v) {
                    case 'background':
                      showChatBackgroundSheet(context, convo.id);
                    case 'clear':
                      _confirmClearHistory(context, ref, convo);
                    case 'leave':
                      _confirmLeave(context, ref, convo);
                    case 'disband':
                      _confirmDisband(context, ref, convo);
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
                    value: 'leave',
                    child: Text('Leave group'),
                  ),
                  if (isSelfAdmin)
                    const PopupMenuItem(
                      value: 'disband',
                      child: Text('Delete group for everyone'),
                    ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                children: [
                  _GroupHeader(
                    t: t,
                    name: convo.groupName ?? '(unnamed)',
                    members: convo.distinctMembers.length,
                    epoch: convo.mlsEpoch ?? 0,
                    avatar: notifier.peerAvatarDescriptor(convo),
                    canEditPhoto: isSelfAdmin,
                    onEditPhoto: () => _editPhoto(context, ref, convo),
                  ),
                  _ActionsRow(
                    t: t,
                    muted: convo.muted,
                    disappearingTtl: convo.disappearingTtl,
                    onMute: () => ref
                        .read(conversationsProvider)
                        .setMuted(convo.id, !convo.muted),
                    onDisappearing: () => _editDisappearing(context, ref, convo),
                  ),
                  InkWell(
                    key: const ValueKey('group-shared-media'),
                    onTap: () => context.push(Routes.sharedMedia
                        .replaceFirst(':conversationId', convo.id)),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 14),
                      decoration: BoxDecoration(
                        border: Border(bottom: BorderSide(color: t.border)),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.perm_media_outlined,
                              size: 18, color: t.textMuted),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text('Media, links and files',
                                style: TextStyle(fontSize: 14, color: t.text)),
                          ),
                          Icon(Icons.chevron_right,
                              size: 14, color: t.textFaint),
                        ],
                      ),
                    ),
                  ),
                  _MembersSection(
                    t: t,
                    members: convo.distinctMembers,
                    isSelfAdmin: isSelfAdmin,
                    onAdd: () => _showAddMember(context, ref, convo),
                    onRemove: (m) => _confirmRemove(context, ref, convo, m),
                  ),
                  _DangerSection(
                    t: t,
                    onLeave: () => _confirmLeave(context, ref, convo),
                    onDisband: isSelfAdmin
                        ? () => _confirmDisband(context, ref, convo)
                        : null,
                  ),
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // --- Action handlers ---

  Future<void> _showAddMember(
    BuildContext context,
    WidgetRef ref,
    Conversation convo,
  ) async {
    final notifier = ref.read(conversationsProvider);
    final inGroupAccountIds = convo.members.map((m) => m.accountId).toSet();
    final candidates = notifier.conversations
        .where((c) => c.kind == ConversationKind.oneToOne)
        .where((c) => !inGroupAccountIds.contains(c.peerAccountId))
        .toList();

    if (candidates.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No contacts available to add')),
      );
      return;
    }

    final selected = await showModalBottomSheet<Conversation>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => _AddMemberSheet(candidates: candidates),
    );
    if (selected == null) return;

    try {
      await notifier.addMemberToGroup(
        conversationId: convo.id,
        newMember: MemberSeed(
          accountId: selected.peerAccountId,
          username: selected.peerUsername,
          deviceId: selected.peerDeviceId,
          identityPubKey: selected.peerIdentityPubKey,
          x25519PubKey: selected.peerX25519PubKey,
        ),
      );
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to add member: $e')),
        );
      }
    }
  }

  Future<void> _confirmRemove(
    BuildContext context,
    WidgetRef ref,
    Conversation convo,
    GroupMember target,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Remove ${target.username}?'),
        content: const Text("They won't see new messages from this group."),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final notifier = ref.read(conversationsProvider);
    try {
      await notifier.removeMemberFromGroup(
        conversationId: convo.id,
        targetDeviceId: target.deviceId,
      );
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to remove: $e')),
        );
      }
    }
  }

  Future<void> _confirmClearHistory(
    BuildContext context,
    WidgetRef ref,
    Conversation convo,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear chat history?'),
        content: const Text(
          'This deletes every message in this group on this device. You stay in '
          'the group and other members keep their copies. This cannot be undone.',
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
    await ref.read(conversationsProvider).clearMessages(convo.id);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Chat history cleared')),
      );
    }
  }

  /// Admin-only: choose a new group photo (or remove the current one), upload it
  /// as encrypted media, and fan the new descriptor out to the group.
  Future<void> _editPhoto(
    BuildContext context,
    WidgetRef ref,
    Conversation convo,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final notifier = ref.read(conversationsProvider);
    final picker = GroupPhotoPicker(ref.read(mediaPipelineProvider));
    final hasPhoto = convo.groupAvatar != null;
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Choose photo'),
              onTap: () => Navigator.of(ctx).pop('choose'),
            ),
            if (hasPhoto)
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: const Text('Remove photo'),
                onTap: () => Navigator.of(ctx).pop('remove'),
              ),
          ],
        ),
      ),
    );
    if (choice == null) return;
    try {
      if (choice == 'remove') {
        await notifier.setGroupAvatar(convo.id, null);
        return;
      }
      // The gallery is a separate activity — don't re-prompt the app lock.
      ref.read(appLockControllerProvider).suppressNextBackgroundLock();
      final photo = await picker.pick();
      if (photo == null) return;
      await notifier.setGroupAvatar(convo.id, await picker.upload(photo));
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Couldn’t update the group photo: $e')),
      );
    }
  }

  Future<void> _editDisappearing(
    BuildContext context,
    WidgetRef ref,
    Conversation convo,
  ) async {
    final chosen = await showDisappearingPicker(
      context,
      current: convo.disappearingTtl,
    );
    if (chosen == null) return;
    await ref.read(conversationsProvider).setDisappearingTtl(convo.id, chosen);
  }

  /// Admin only: delete the group for EVERY member (their devices drop it too).
  Future<void> _confirmDisband(
    BuildContext context,
    WidgetRef ref,
    Conversation convo,
  ) async {
    final name = convo.groupName ?? 'this group';
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Delete $name for everyone?'),
        content: const Text(
          'This deletes the group and all its messages for every member, on '
          'all of their devices. This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete for everyone'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final notifier = ref.read(conversationsProvider);
    try {
      await notifier.disbandGroup(convo.id);
      if (context.mounted) context.go(Routes.chatList);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to delete group: $e')),
        );
      }
    }
  }

  Future<void> _confirmLeave(
    BuildContext context,
    WidgetRef ref,
    Conversation convo,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Leave this group?'),
        content: const Text(
          "You won't get new messages, and this chat will be deleted from "
          'your devices.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Leave'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final notifier = ref.read(conversationsProvider);
    try {
      final selfDeviceId = await notifier.selfDeviceId();
      await notifier.removeMemberFromGroup(
        conversationId: convo.id,
        targetDeviceId: selfDeviceId,
      );
      if (context.mounted) context.go(Routes.chatList);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to leave: $e')),
        );
      }
    }
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({required this.t, this.menu});
  final DesignTokens t;
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
              'Group info',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: t.text,
              ),
            ),
          ),
          menu ?? const SizedBox(width: 36),
        ],
      ),
    );
  }
}

class _GroupHeader extends StatelessWidget {
  const _GroupHeader({
    required this.t,
    required this.name,
    required this.members,
    required this.epoch,
    required this.avatar,
    required this.canEditPhoto,
    required this.onEditPhoto,
  });
  final DesignTokens t;
  final String name;
  final int members;
  final int epoch;
  final MediaDescriptor? avatar;

  /// Admins only — mirrors who may add members.
  final bool canEditPhoto;
  final VoidCallback onEditPhoto;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 24),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: t.border)),
      ),
      child: Column(
        children: [
          Stack(
            clipBehavior: Clip.none,
            children: [
              if (avatar != null)
                AvatarImage(
                  name: name,
                  descriptor: avatar,
                  size: 72,
                  enlargeOnTap: true,
                )
              else
                Container(
                  width: 72,
                  height: 72,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: t.surfaceAlt,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: t.border),
                  ),
                  child:
                      Icon(Icons.group_outlined, size: 32, color: t.textMuted),
                ),
              if (canEditPhoto)
                Positioned(
                  right: -6,
                  bottom: -6,
                  child: Material(
                    color: t.accent,
                    shape: const CircleBorder(),
                    child: InkWell(
                      key: const ValueKey('edit-group-photo'),
                      customBorder: const CircleBorder(),
                      onTap: onEditPhoto,
                      child: Padding(
                        padding: const EdgeInsets.all(6),
                        child: Icon(Icons.camera_alt_outlined,
                            size: 16, color: t.accentOn),
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            name,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w500,
              color: t.text,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '$members members · MLS group · epoch $epoch',
            style: monoStyle(
              fontSize: 11,
              color: t.textMuted,
              letterSpacing: 0.3,
            ),
          ),
        ],
      ),
    );
  }
}

class _ActionsRow extends StatelessWidget {
  const _ActionsRow({
    required this.t,
    required this.muted,
    required this.disappearingTtl,
    required this.onMute,
    required this.onDisappearing,
  });
  final DesignTokens t;
  final bool muted;
  final int disappearingTtl;
  final VoidCallback onMute;
  final VoidCallback onDisappearing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          _action(
            t,
            muted
                ? Icons.notifications_off_outlined
                : Icons.notifications_outlined,
            muted ? 'Muted' : 'Mute',
            onTap: onMute,
            active: muted,
          ),
          const SizedBox(width: 8),
          _action(
            t,
            Icons.hourglass_empty,
            disappearingShortLabel(disappearingTtl),
            onTap: onDisappearing,
          ),
        ],
      ),
    );
  }

  Widget _action(
    DesignTokens t,
    IconData icon,
    String label, {
    VoidCallback? onTap,
    bool active = false,
  }) {
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
          decoration: BoxDecoration(
            color: active ? t.accent.withValues(alpha: 0.12) : t.surface,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: active ? t.accent : t.border),
          ),
          child: Column(
            children: [
              Icon(icon, size: 18, color: active ? t.accent : t.text),
              const SizedBox(height: 4),
              Text(
                label,
                style: monoStyle(
                  fontSize: 10,
                  color: active ? t.accent : t.textMuted,
                  letterSpacing: 0.3,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MembersSection extends StatelessWidget {
  const _MembersSection({
    required this.t,
    required this.members,
    required this.isSelfAdmin,
    required this.onAdd,
    required this.onRemove,
  });
  final DesignTokens t;
  final List<GroupMember> members;
  final bool isSelfAdmin;
  final VoidCallback onAdd;
  final void Function(GroupMember) onRemove;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              'MEMBERS',
              style: monoStyle(fontSize: 10, color: t.textFaint, letterSpacing: 1),
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
                  for (var i = 0; i < members.length; i++)
                    _MemberRow(
                      t: t,
                      m: members[i],
                      last: i == members.length - 1 && !isSelfAdmin,
                      isSelfAdmin: isSelfAdmin,
                      onRemove: onRemove,
                    ),
                  if (isSelfAdmin) _AddMemberRow(t: t, onTap: onAdd),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MemberRow extends StatelessWidget {
  const _MemberRow({
    required this.t,
    required this.m,
    required this.last,
    required this.isSelfAdmin,
    required this.onRemove,
  });
  final DesignTokens t;
  final GroupMember m;
  final bool last;
  final bool isSelfAdmin;
  final void Function(GroupMember) onRemove;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onLongPress: (isSelfAdmin && !m.isSelf) ? () => _showRemovePopup(context) : null,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          border: last ? null : Border(bottom: BorderSide(color: t.border)),
        ),
        child: Row(
          children: [
            NanbAvatar(name: m.username, size: 36),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        m.isSelf ? '${m.username} (you)' : m.username,
                        style: monoStyle(fontSize: 13, color: t.text),
                      ),
                    ],
                  ),
                  if (m.isAdmin)
                    Text(
                      'Admin',
                      style: monoStyle(
                        fontSize: 10,
                        color: t.textMuted,
                        letterSpacing: 0.3,
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

  Future<void> _showRemovePopup(BuildContext context) async {
    final result = await showMenu<String>(
      context: context,
      position: const RelativeRect.fromLTRB(100, 200, 0, 0),
      items: const [
        PopupMenuItem<String>(value: 'remove', child: Text('Remove')),
      ],
    );
    if (result == 'remove') {
      onRemove(m);
    }
  }
}

class _AddMemberRow extends StatelessWidget {
  const _AddMemberRow({required this.t, required this.onTap});
  final DesignTokens t;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: t.border)),
        ),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: t.surfaceAlt,
                borderRadius: BorderRadius.circular(18),
              ),
              child: Icon(Icons.add, size: 18, color: t.text),
            ),
            const SizedBox(width: 10),
            Text(
              'Add member',
              style: monoStyle(
                fontSize: 12,
                color: t.text,
                letterSpacing: 0.3,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DangerSection extends StatelessWidget {
  const _DangerSection(
      {required this.t, required this.onLeave, this.onDisband});
  final DesignTokens t;
  final VoidCallback onLeave;

  /// Non-null only for a group admin: deletes the group for every member.
  final VoidCallback? onDisband;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              'DANGER ZONE',
              style: monoStyle(
                fontSize: 10,
                color: t.textFaint,
                letterSpacing: 1,
              ),
            ),
          ),
          NanbButton(
            label: 'Leave group',
            kind: NanbButtonKind.danger,
            fullWidth: true,
            icon: Icons.delete_outline,
            onPressed: onLeave,
          ),
          if (onDisband != null) ...[
            const SizedBox(height: 8),
            NanbButton(
              label: 'Delete group for everyone',
              kind: NanbButtonKind.danger,
              fullWidth: true,
              icon: Icons.delete_forever,
              onPressed: onDisband,
            ),
          ],
        ],
      ),
    );
  }
}

class _AddMemberSheet extends StatelessWidget {
  const _AddMemberSheet({required this.candidates});
  final List<Conversation> candidates;

  @override
  Widget build(BuildContext context) {
    final t = DesignTokens.of(context);
    return SafeArea(
      child: Container(
        decoration: BoxDecoration(
          color: t.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
          border: Border(top: BorderSide(color: t.border)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Text(
                    'Add member',
                    style: TextStyle(
                      fontSize: 15,
                      color: t.text,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 320),
              // Transparent Material gives the ListTiles an ink surface that
              // sits in front of the sheet's colored Container — without it,
              // Flutter asserts that the tile's splash would be hidden.
              child: Material(
                type: MaterialType.transparency,
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: candidates.length,
                  itemBuilder: (ctx, i) {
                    final c = candidates[i];
                    return ListTile(
                      key: ValueKey('add-candidate-${c.id}'),
                      leading: NanbAvatar(name: c.peerUsername, size: 36),
                      title: Text(c.peerUsername),
                      onTap: () => Navigator.of(ctx).pop(c),
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
