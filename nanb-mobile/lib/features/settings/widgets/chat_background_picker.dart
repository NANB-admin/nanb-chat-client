import 'dart:io';

import 'package:flutter/material.dart';

import '../../../app/design_tokens.dart';
import '../../chat/widgets/chat_background_view.dart';
import '../models/chat_background.dart';

/// Row of backdrop swatches (the presets plus "Photo") for the Appearance
/// screen. Tapping a preset selects it; tapping Photo asks the host to pick one.
class ChatBackgroundPicker extends StatelessWidget {
  const ChatBackgroundPicker({
    super.key,
    required this.selected,
    required this.customPath,
    required this.onSelect,
    required this.onPickPhoto,
  });

  /// The highlighted swatch, or null when none is (e.g. a per-chat override
  /// that follows the default).
  final ChatBackground? selected;
  final String customPath;
  final ValueChanged<ChatBackground> onSelect;
  final VoidCallback onPickPhoto;

  @override
  Widget build(BuildContext context) {
    final t = DesignTokens.of(context);
    return Padding(
      padding: const EdgeInsets.all(14),
      child: Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          for (final b in ChatBackground.values)
            GestureDetector(
              onTap: () =>
                  b == ChatBackground.custom ? onPickPhoto() : onSelect(b),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 64,
                    height: 88,
                    clipBehavior: Clip.antiAlias,
                    decoration: BoxDecoration(
                      color: t.surfaceAlt,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: selected == b ? t.accent : t.border,
                        width: selected == b ? 2.5 : 1,
                      ),
                    ),
                    child: _swatch(b, t),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    b.label,
                    style: TextStyle(fontSize: 11, color: t.textMuted),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _swatch(ChatBackground b, DesignTokens t) {
    if (b == ChatBackground.custom) {
      if (selected == b && customPath.isNotEmpty) {
        return Image.file(
          File(customPath),
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) =>
              Icon(Icons.image_outlined, color: t.textMuted),
        );
      }
      return Icon(Icons.add_photo_alternate_outlined, color: t.textMuted);
    }
    return ChatBackgroundView(
      background: b,
      customPath: '',
      child: const SizedBox.expand(),
    );
  }
}
