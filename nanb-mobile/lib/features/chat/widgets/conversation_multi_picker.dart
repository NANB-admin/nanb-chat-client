import 'package:flutter/material.dart';

import '../../../app/design_tokens.dart';
import '../conversations_notifier.dart';
import '../models/conversation.dart';
import '../models/conversation_kind.dart';
import 'avatar_image.dart';

/// A checkable list of conversations. Selection state is owned by the host
/// (it needs the set to enable its Send button); this widget only renders rows
/// and reports taps. Shared by the OS share-target screen and the in-thread
/// "Forward to…" sheet so both multi-select identically.
class ConversationMultiPicker extends StatelessWidget {
  const ConversationMultiPicker({
    super.key,
    required this.notifier,
    required this.conversations,
    required this.selectedIds,
    required this.onToggle,
    this.enabled = true,
    this.shrinkWrap = false,
  });

  final ConversationsNotifier notifier;
  final List<Conversation> conversations;
  final Set<String> selectedIds;
  final ValueChanged<Conversation> onToggle;
  final bool enabled;
  final bool shrinkWrap;

  @override
  Widget build(BuildContext context) {
    final t = DesignTokens.of(context);
    return ListView.builder(
      shrinkWrap: shrinkWrap,
      itemCount: conversations.length,
      itemBuilder: (context, i) {
        final c = conversations[i];
        final selected = selectedIds.contains(c.id);
        return ListTile(
          key: ValueKey('pick-${c.id}'),
          enabled: enabled,
          leading: AvatarImage(
            name: notifier.displayNameFor(c),
            descriptor: notifier.peerAvatarDescriptor(c),
            size: 40,
          ),
          title: Text(notifier.displayNameFor(c)),
          subtitle: c.kind == ConversationKind.group
              ? Text('${c.members.length} members',
                  style: TextStyle(fontSize: 11, color: t.textFaint))
              : null,
          trailing: Icon(
            selected ? Icons.check_circle : Icons.circle_outlined,
            color: selected ? t.accent : t.textFaint,
          ),
          onTap: () => onToggle(c),
        );
      },
    );
  }
}
