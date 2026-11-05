import 'package:flutter/material.dart';

import '../../../app/design_tokens.dart';
import '../../../app/theme.dart';
import '../conversations_notifier.dart';
import '../models/conversation.dart';
import 'conversation_multi_picker.dart';

/// Bottom sheet for "Forward to…": tick any number of conversations, then Send.
/// Pops with the chosen conversations (in tap order), or null when dismissed.
class ForwardSheet extends StatefulWidget {
  const ForwardSheet({
    super.key,
    required this.notifier,
    required this.targets,
  });

  final ConversationsNotifier notifier;
  final List<Conversation> targets;

  /// Shows the sheet and returns the picked conversations (empty/null = none).
  static Future<List<Conversation>?> show(
    BuildContext context, {
    required ConversationsNotifier notifier,
    required List<Conversation> targets,
  }) {
    return showModalBottomSheet<List<Conversation>>(
      context: context,
      isScrollControlled: true,
      builder: (_) => ForwardSheet(notifier: notifier, targets: targets),
    );
  }

  @override
  State<ForwardSheet> createState() => _ForwardSheetState();
}

class _ForwardSheetState extends State<ForwardSheet> {
  final Set<String> _selected = <String>{};

  void _toggle(Conversation c) {
    setState(() {
      if (!_selected.remove(c.id)) _selected.add(c.id);
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = DesignTokens.of(context);
    final height = MediaQuery.of(context).size.height * 0.7;
    return SafeArea(
      child: SizedBox(
        height: height,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'FORWARD TO',
                  style: monoStyle(
                    fontSize: 10,
                    color: t.textFaint,
                    letterSpacing: 1,
                  ),
                ),
              ),
            ),
            Expanded(
              child: ConversationMultiPicker(
                notifier: widget.notifier,
                conversations: widget.targets,
                selectedIds: _selected,
                onToggle: _toggle,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  key: const ValueKey('forward-send'),
                  onPressed: _selected.isEmpty
                      ? null
                      : () => Navigator.pop(context, [
                            for (final c in widget.targets)
                              if (_selected.contains(c.id)) c,
                          ]),
                  icon: const Icon(Icons.send),
                  label: Text(_selected.isEmpty
                      ? 'Select chats'
                      : 'Send to ${_selected.length}'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
