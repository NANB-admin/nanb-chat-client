import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../../app/design_tokens.dart';
import '../../../app/providers.dart';
import '../../settings/widgets/chat_background_picker.dart';
import '../models/chat_background_override.dart';
import '../services/conversation_background_photo_store.dart';

/// Opens the per-chat "Chat background" sheet for [conversationId].
Future<void> showChatBackgroundSheet(
    BuildContext context, String conversationId) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => ChatBackgroundSheet(conversationId: conversationId),
  );
}

/// Reuses the Appearance [ChatBackgroundPicker] to set a per-chat override, plus
/// a "Use default" choice that clears it. Presets sync to the account's other
/// devices; a photo stays on this device.
class ChatBackgroundSheet extends ConsumerWidget {
  const ChatBackgroundSheet({super.key, required this.conversationId});

  final String conversationId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = DesignTokens.of(context);
    final notifier = ref.watch(conversationsProvider);
    final current = notifier.backgroundOverrideOf(conversationId);
    return SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ListTile(
              key: const ValueKey('chat-bg-use-default'),
              title: const Text('Use default'),
              subtitle: const Text('Follow the Appearance setting'),
              trailing: current.isDefault
                  ? Icon(Icons.check, color: t.accent)
                  : null,
              onTap: () => _choose(
                  ref, current, const ChatBackgroundOverride.useDefault()),
            ),
            ChatBackgroundPicker(
              selected: current.preset,
              customPath: current.photoPath,
              onSelect: (b) =>
                  _choose(ref, current, ChatBackgroundOverride.preset(b)),
              onPickPhoto: () => _pickPhoto(context, ref, current),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Text(
                'A photo background stays on this device only; it is not '
                'synced to your other devices. Colours and patterns are.',
                style: TextStyle(fontSize: 12, color: t.textMuted, height: 1.4),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _choose(WidgetRef ref, ChatBackgroundOverride previous,
      ChatBackgroundOverride next) async {
    await ref
        .read(conversationsProvider)
        .setBackgroundOverride(conversationId, next);
    if (previous.isPhoto && !next.isPhoto) {
      try {
        await const ConversationBackgroundPhotoStore().clear(conversationId);
      } catch (_) {/* best effort */}
    }
  }

  Future<void> _pickPhoto(BuildContext context, WidgetRef ref,
      ChatBackgroundOverride previous) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final picked = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 2048,
        maxHeight: 2048,
        imageQuality: 85,
      );
      if (picked == null) return;
      final saved = await const ConversationBackgroundPhotoStore()
          .save(conversationId, picked.path);
      await ref
          .read(conversationsProvider)
          .setBackgroundOverride(conversationId, ChatBackgroundOverride.photo(saved));
    } catch (_) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Couldn’t set that photo.')),
      );
    }
  }
}
