import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/design_tokens.dart';
import '../../app/providers.dart';
import '../chat/widgets/nanb_avatar.dart';
import 'widgets/settings_scaffold.dart';

/// Lists the accounts the user has blocked (the `blocked` flag on a 1:1
/// conversation) with a one-tap Unblock. Blocked conversations are hidden from
/// the chat list, so this is the only place they surface.
class BlocksScreen extends ConsumerWidget {
  const BlocksScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = DesignTokens.of(context);
    final notifier = ref.watch(conversationsProvider);
    final blocked = notifier.conversations.where((c) => c.blocked).toList()
      ..sort((a, b) => a.peerUsername
          .toLowerCase()
          .compareTo(b.peerUsername.toLowerCase()));

    if (blocked.isEmpty) {
      return SettingsScaffold(
        title: 'Blocked',
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.block_outlined, size: 36, color: t.textMuted),
                const SizedBox(height: 12),
                Text(
                  'No blocked accounts',
                  style: TextStyle(fontSize: 14, color: t.text),
                ),
                const SizedBox(height: 8),
                Text(
                  'Tap "Block" on a contact profile to stop receiving messages '
                  'from them. The block list shows up here.',
                  textAlign: TextAlign.center,
                  style:
                      TextStyle(fontSize: 12, color: t.textMuted, height: 1.5),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return SettingsScaffold(
      title: 'Blocked',
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: blocked.length,
        separatorBuilder: (_, _) =>
            Divider(height: 1, color: t.border, indent: 64),
        itemBuilder: (context, i) {
          final c = blocked[i];
          return ListTile(
            leading: NanbAvatar(name: c.peerUsername, size: 40),
            title: Text(
              c.peerUsername,
              style: TextStyle(fontSize: 14, color: t.text),
            ),
            trailing: TextButton(
              onPressed: () => notifier.setBlocked(c.id, false),
              child: Text(
                'Unblock',
                style: TextStyle(color: t.accent),
              ),
            ),
          );
        },
      ),
    );
  }
}
