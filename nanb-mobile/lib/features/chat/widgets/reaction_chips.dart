import 'package:flutter/material.dart';

import '../../../app/design_tokens.dart';
import '../../../app/theme.dart';
import 'full_emoji_picker.dart';

/// The quick-reaction emoji set offered in the long-press picker. Kept small
/// and universal; the wire carries the literal emoji, so this list can grow
/// without any protocol change.
const List<String> kQuickReactionEmojis = ['👍', '❤️', '😂', '😮', '😢', '🙏'];

/// Renders the reaction summary beneath a message bubble: one pill per distinct
/// emoji with a count (shown when >1), the current user's own reaction
/// highlighted. Tapping a pill toggles the user's reaction with that emoji.
///
/// [reactions] is the message's `reactorAccountId → emoji` map; [myAccountId]
/// is the current user's account id (empty before connect) used to highlight
/// and to know which pill is "mine".
class ReactionChips extends StatelessWidget {
  const ReactionChips({
    super.key,
    required this.reactions,
    required this.myAccountId,
    this.onTapEmoji,
    this.alignEnd = false,
  });

  final Map<String, String> reactions;
  final String myAccountId;
  final void Function(String emoji)? onTapEmoji;

  /// Align the pills to the trailing edge (for the user's own messages).
  final bool alignEnd;

  @override
  Widget build(BuildContext context) {
    if (reactions.isEmpty) return const SizedBox.shrink();
    final t = DesignTokens.of(context);
    // Count per emoji, preserving first-seen order for a stable layout.
    final counts = <String, int>{};
    for (final emoji in reactions.values) {
      counts[emoji] = (counts[emoji] ?? 0) + 1;
    }
    final mineEmoji = myAccountId.isEmpty ? null : reactions[myAccountId];
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      alignment: alignEnd ? WrapAlignment.end : WrapAlignment.start,
      children: [
        for (final entry in counts.entries)
          _ReactionPill(
            emoji: entry.key,
            count: entry.value,
            mine: entry.key == mineEmoji,
            t: t,
            onTap: onTapEmoji == null ? null : () => onTapEmoji!(entry.key),
          ),
      ],
    );
  }
}

class _ReactionPill extends StatelessWidget {
  const _ReactionPill({
    required this.emoji,
    required this.count,
    required this.mine,
    required this.t,
    this.onTap,
  });
  final String emoji;
  final int count;
  final bool mine;
  final DesignTokens t;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: mine ? t.accent.withValues(alpha: 0.18) : t.surfaceAlt,
      shape: StadiumBorder(
        side: BorderSide(color: mine ? t.accent : t.border, width: 1),
      ),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(emoji, style: const TextStyle(fontSize: 13)),
              if (count > 1) ...[
                const SizedBox(width: 4),
                Text(
                  '$count',
                  style: monoStyle(
                    fontSize: 11,
                    color: mine ? t.accent : t.textMuted,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// The horizontal emoji bar shown at the top of the message long-press sheet:
/// the quick-reaction set plus a trailing "+" that opens the full emoji
/// catalogue so any emoji can be used. Highlights [selectedEmoji] (the user's
/// current reaction on this message) and calls [onPick] with the chosen emoji.
class ReactionPickerRow extends StatelessWidget {
  const ReactionPickerRow({
    super.key,
    required this.onPick,
    this.selectedEmoji,
  });

  final void Function(String emoji) onPick;
  final String? selectedEmoji;

  @override
  Widget build(BuildContext context) {
    final t = DesignTokens.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          for (final emoji in kQuickReactionEmojis)
            InkWell(
              customBorder: const CircleBorder(),
              onTap: () => onPick(emoji),
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: emoji == selectedEmoji
                      ? t.accent.withValues(alpha: 0.18)
                      : Colors.transparent,
                ),
                child: Text(emoji, style: const TextStyle(fontSize: 24)),
              ),
            ),
          // "+" — open the full catalogue and react with whatever they pick.
          InkWell(
            customBorder: const CircleBorder(),
            onTap: () async {
              final picked = await showFullEmojiPicker(context);
              if (picked != null) onPick(picked);
            },
            child: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: t.surfaceAlt,
              ),
              child: Icon(Icons.add, size: 24, color: t.textMuted),
            ),
          ),
        ],
      ),
    );
  }
}
