import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../app/design_tokens.dart';
import '../../../app/router.dart';

/// Bottom sheet shown when the FAB on `ChatListScreen` is tapped (Plan C
/// §10.2). Offers two creation entry points: a regular 1:1 chat or a new
/// group conversation. Closes itself before navigating so the back button
/// returns to the chat list cleanly.
class NewChatOrGroupSheet extends StatelessWidget {
  const NewChatOrGroupSheet({super.key});

  static const String newGroupRoute = '/chat-list/new-group';

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
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _row(
              context,
              icon: Icons.chat_bubble_outline,
              label: 'New chat',
              onTap: () {
                Navigator.of(context).pop();
                context.push(Routes.newChat);
              },
            ),
            _row(
              context,
              icon: Icons.group_outlined,
              label: 'New group',
              onTap: () {
                Navigator.of(context).pop();
                context.push(newGroupRoute);
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(
    BuildContext context, {
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    final t = DesignTokens.of(context);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Icon(icon, size: 22, color: t.text),
            const SizedBox(width: 14),
            Text(
              label,
              style: TextStyle(fontSize: 15, color: t.text),
            ),
          ],
        ),
      ),
    );
  }
}
