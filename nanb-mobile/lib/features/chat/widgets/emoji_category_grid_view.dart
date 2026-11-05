import 'package:flutter/material.dart';

import '../models/emoji_category.dart';

/// Renders one [EmojiCategory]'s emoji as a fixed 8-column grid, calling [onTap]
/// with the tapped emoji. Shared by the composer's inline picker and the
/// reaction picker so both grids look and behave identically.
class EmojiCategoryGridView extends StatelessWidget {
  const EmojiCategoryGridView({
    super.key,
    required this.category,
    required this.onTap,
  });

  final EmojiCategory category;
  final ValueChanged<String> onTap;

  @override
  Widget build(BuildContext context) {
    return GridView.count(
      crossAxisCount: 8,
      padding: const EdgeInsets.all(8),
      children: [
        for (final e in category.emoji)
          InkWell(
            onTap: () => onTap(e),
            child: Center(
              child: Text(e, style: const TextStyle(fontSize: 24)),
            ),
          ),
      ],
    );
  }
}
