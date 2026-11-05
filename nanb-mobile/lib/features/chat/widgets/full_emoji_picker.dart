import 'package:flutter/material.dart';

import '../../../app/design_tokens.dart';
import '../models/emoji_category.dart';
import 'emoji_category_grid_view.dart';

/// Opens the full emoji catalogue as a modal sheet and resolves with the emoji
/// the user taps, or null if they dismiss it without picking. Used by the
/// reaction picker's "+" button so a reaction isn't limited to the quick set.
Future<String?> showFullEmojiPicker(BuildContext context) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => const FullEmojiPicker(),
  );
}

/// The full categorised emoji catalogue rendered as a tabbed grid. Tapping an
/// emoji pops the enclosing route with that emoji as the result. Emoji-only and
/// one-shot — it has none of the composer panel's insert/backspace/GIF
/// affordances; it exists purely to choose a single emoji to react with.
class FullEmojiPicker extends StatelessWidget {
  const FullEmojiPicker({super.key});

  @override
  Widget build(BuildContext context) {
    final t = DesignTokens.of(context);
    final height = MediaQuery.of(context).size.height * 0.6;
    return DefaultTabController(
      length: kEmojiCategories.length,
      child: Container(
        height: height,
        decoration: BoxDecoration(
          color: t.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            children: [
              // Drag grabber — the usual modal-sheet affordance.
              Padding(
                padding: const EdgeInsets.only(top: 8, bottom: 4),
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: t.border,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              TabBar(
                isScrollable: true,
                labelColor: t.accent,
                unselectedLabelColor: t.textMuted,
                indicatorColor: t.accent,
                tabs: [
                  for (final c in kEmojiCategories)
                    Tab(
                      child: Text(c.icon, style: const TextStyle(fontSize: 18)),
                    ),
                ],
              ),
              Expanded(
                child: TabBarView(
                  children: [
                    for (final c in kEmojiCategories)
                      EmojiCategoryGridView(
                        category: c,
                        onTap: (emoji) => Navigator.of(context).pop(emoji),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
