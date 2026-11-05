import 'package:flutter/material.dart';

import '../../../app/design_tokens.dart';

/// Preview shown on the caption screen for media that has no inline picture to
/// show (a file, or a video before it is sent): a big icon, its name and size.
class AttachmentPreviewCard extends StatelessWidget {
  const AttachmentPreviewCard({
    super.key,
    required this.icon,
    required this.name,
    required this.sizeLabel,
  });

  final IconData icon;
  final String name;
  final String sizeLabel;

  @override
  Widget build(BuildContext context) {
    final t = DesignTokens.of(context);
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 72, color: t.textMuted),
          const SizedBox(height: 16),
          Text(
            name,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 15, color: t.text),
          ),
          const SizedBox(height: 4),
          Text(sizeLabel, style: TextStyle(fontSize: 12, color: t.textMuted)),
        ],
      ),
    );
  }
}
