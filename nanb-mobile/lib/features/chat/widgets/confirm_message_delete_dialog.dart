import 'package:flutter/material.dart';

/// Asks before deleting a message. [forEveryone] is the "Delete for everyone"
/// choice, which also removes it from everyone else in the chat. Resolves true
/// only on an explicit "Delete".
Future<bool> confirmMessageDelete(
  BuildContext context, {
  required bool forEveryone,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(forEveryone ? 'Delete for everyone?' : 'Delete for you?'),
      content: Text(
        forEveryone
            ? 'This message will be deleted for everyone in this chat, on all '
                'of their devices. This can\'t be undone.'
            : 'This message will be deleted from this device and your other '
                'devices. Others in the chat will still see it.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text('Delete'),
        ),
      ],
    ),
  );
  return ok ?? false;
}
