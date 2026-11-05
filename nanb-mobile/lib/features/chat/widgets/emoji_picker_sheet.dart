import 'package:flutter/material.dart';

import '../../../app/design_tokens.dart';
import '../../../core/gif/gif_result.dart';
import '../models/emoji_category.dart';
import '../models/sticker.dart';
import 'emoji_category_grid_view.dart';
import 'gif_browser.dart';
import 'sticker_browser.dart';

/// Static cursor helpers for the emoji picker (insert / backspace), unit-tested
/// directly. The visible UI is [EmojiPickerPanel].
///
/// Deliberately a curated set (not the full Unicode catalogue) â€” it renders
/// with the system emoji font, needs no package/network, and covers the
/// emoji people actually reach for in chat.
class EmojiPickerSheet {
  EmojiPickerSheet._();

  /// Inserts [emoji] at the current cursor (replacing any selection) and moves
  /// the caret to just after it. Used by the panel and unit-tested directly.
  static void insert(TextEditingController controller, String emoji) {
    final value = controller.value;
    final sel = value.selection;
    final text = value.text;
    final start = sel.isValid ? sel.start : text.length;
    final end = sel.isValid ? sel.end : text.length;
    final newText = text.replaceRange(start, end, emoji);
    controller.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: start + emoji.length),
      composing: TextRange.empty,
    );
  }

  /// Deletes backwards from the caret: the current selection if there is one,
  /// otherwise the single grapheme cluster before the caret. Operating on whole
  /// clusters means a multi-code-unit emoji (ðŸ‘, ðŸ‘¨â€ðŸ‘©â€ðŸ‘§) is removed in one press
  /// rather than leaving a broken half. The soft keyboard is hidden while the
  /// picker is open, so this is the only way to fix a mistaken pick.
  static void backspace(TextEditingController controller) {
    final value = controller.value;
    final sel = value.selection;
    final text = value.text;
    if (text.isEmpty) return;
    if (sel.isValid && !sel.isCollapsed) {
      controller.value = TextEditingValue(
        text: text.replaceRange(sel.start, sel.end, ''),
        selection: TextSelection.collapsed(offset: sel.start),
        composing: TextRange.empty,
      );
      return;
    }
    final end = sel.isValid ? sel.start : text.length;
    if (end == 0) return;
    final before = text.substring(0, end);
    final clusters = before.characters;
    if (clusters.isEmpty) return;
    final start = end - clusters.last.length;
    controller.value = TextEditingValue(
      text: text.replaceRange(start, end, ''),
      selection: TextSelection.collapsed(offset: start),
      composing: TextRange.empty,
    );
  }
}

/// The emoji picker UI, rendered INLINE below the composer (in place of the
/// keyboard) â€” not as a modal sheet â€” so the text field stays visible above it
/// and the user can watch their picks land and send without dismissing
/// anything. The host (chat thread) toggles it, hides the soft keyboard while
/// it's open, and supplies [onClose] / [onSend].
class EmojiPickerPanel extends StatelessWidget {
  const EmojiPickerPanel({
    super.key,
    required this.controller,
    this.onClose,
    this.onGifSelected,
    this.onStickerSelected,
    this.height = 300,
  });

  final TextEditingController controller;

  /// Collapses the panel (the host clears its visibility flag). Sending is done
  /// from the composer's own send button, which stays visible above the panel â€”
  /// so the panel has no send affordance of its own.
  final VoidCallback? onClose;

  /// Called when the user taps a GIF in the "GIF" tab. When null (or no GIPHY
  /// key is configured) the GIF tab is omitted and the panel is emoji-only. The
  /// host downloads + sends the GIF through the encrypted media pipeline.
  final ValueChanged<GifResult>? onGifSelected;

  /// Called when the user taps a sticker in the "Stickers" tab. When null the
  /// tab is omitted. The host loads the sticker's bytes and sends it through the
  /// encrypted media pipeline.
  final ValueChanged<Sticker>? onStickerSelected;

  /// Panel height in logical pixels â€” roughly a soft-keyboard's height.
  final double height;

  @override
  Widget build(BuildContext context) {
    final t = DesignTokens.of(context);
    // The GIPHY key now lives server-side, so the tab shows whenever a GIF
    // handler is wired; a server without a key just makes the browser error.
    final hasGif = onGifSelected != null;
    final hasStickers = onStickerSelected != null;
    final leadingTabs = (hasStickers ? 1 : 0) + (hasGif ? 1 : 0);
    return DefaultTabController(
      length: kEmojiCategories.length + leadingTabs,
      // Open on the first emoji category even when the GIF tab is present, so
      // tapping the (smiley) emoji button shows emoji â€” GIF sits one tab away.
      initialIndex: leadingTabs,
      child: Container(
        height: height,
        decoration: BoxDecoration(
          color: t.surface,
          border: Border(top: BorderSide(color: t.border)),
        ),
        child: Column(
          children: [
            _PanelHeader(
              controller: controller,
              onClose: onClose,
              t: t,
            ),
            TabBar(
              isScrollable: true,
              labelColor: t.accent,
              unselectedLabelColor: t.textMuted,
              indicatorColor: t.accent,
              tabs: [
                if (hasStickers)
                  const Tab(
                    child: Text(
                      'Stickers',
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
                    ),
                  ),
                if (hasGif)
                  const Tab(
                    child: Text(
                      'GIF',
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
                    ),
                  ),
                for (final c in kEmojiCategories)
                  Tab(
                    child: Text(c.icon, style: const TextStyle(fontSize: 18)),
                  ),
              ],
            ),
            Expanded(
              child: TabBarView(
                children: [
                  if (hasStickers)
                    StickerBrowser(onSelected: onStickerSelected!),
                  if (hasGif) GifBrowser(onSelected: onGifSelected!),
                  for (final c in kEmojiCategories)
                    EmojiCategoryGridView(
                      category: c,
                      onTap: (e) => EmojiPickerSheet.insert(controller, e),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Panel top bar: backspace (the soft keyboard is hidden while the panel is
/// open, so this is the only delete affordance) and a collapse/close button.
/// There is no send affordance here â€” the composer's send button stays visible
/// above the panel.
class _PanelHeader extends StatelessWidget {
  const _PanelHeader({
    required this.controller,
    required this.onClose,
    required this.t,
  });

  final TextEditingController controller;
  final VoidCallback? onClose;
  final DesignTokens t;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 2, 4, 0),
      child: Row(
        children: [
          IconButton(
            icon: Icon(Icons.backspace_outlined, size: 20, color: t.textMuted),
            tooltip: 'Delete',
            visualDensity: VisualDensity.compact,
            onPressed: () => EmojiPickerSheet.backspace(controller),
          ),
          const Spacer(),
          IconButton(
            icon: Icon(Icons.keyboard_arrow_down, size: 22, color: t.textMuted),
            tooltip: 'Close',
            visualDensity: VisualDensity.compact,
            onPressed: onClose,
          ),
        ],
      ),
    );
  }
}
