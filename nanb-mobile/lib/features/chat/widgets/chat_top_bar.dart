import 'package:flutter/material.dart';

import '../../../app/design_tokens.dart';
import '../../../app/theme.dart';
import '../media_pipeline.dart';
import 'avatar_image.dart';

/// Translated from the design's `ChatTopBar`. Back arrow + avatar + name +
/// sub-line + verified shield + overflow.
class ChatTopBar extends StatelessWidget implements PreferredSizeWidget {
  const ChatTopBar({
    super.key,
    required this.name,
    this.sub,
    this.avatar,
    this.verified = false,
    this.isGroup = false,
    this.onBack,
    this.onTitleTap,
    this.onCall,
    this.onVideoCall,
    this.menuActions = const {},
  });

  final String name;

  /// The 1:1 peer's avatar descriptor (encrypted media), or null for initials.
  final MediaDescriptor? avatar;

  /// Renders a group glyph instead of the peer-initials avatar — groups
  /// otherwise looked identical to a 1:1 with the group's name.
  final bool isGroup;

  /// Optional sub-line under the name (e.g. member count for groups).
  /// Hidden when null.
  final String? sub;
  final bool verified;
  final VoidCallback? onBack;

  /// Tapped when the user touches the avatar / name / sub-line area.
  /// Production wires this to the contact profile route.
  final VoidCallback? onTitleTap;

  /// Places a voice call. Non-null only for a callable 1:1 (accepted,
  /// non-blocked); renders a phone button before the overflow menu.
  final VoidCallback? onCall;

  /// Places a video call. Same gating as [onCall]; renders a camera button.
  final VoidCallback? onVideoCall;

  /// Overflow (⋮) menu entries: label → action. Empty map renders the icon
  /// disabled (it was a dead `onPressed: () {}` placeholder before).
  final Map<String, VoidCallback> menuActions;

  @override
  Size get preferredSize => const Size.fromHeight(56);

  @override
  Widget build(BuildContext context) {
    final t = DesignTokens.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: t.surface,
        border: Border(bottom: BorderSide(color: t.border)),
      ),
      child: Row(
        children: [
          IconButton(
            icon: Icon(Icons.arrow_back, color: t.text),
            iconSize: 22,
            padding: const EdgeInsets.all(4),
            constraints: const BoxConstraints(),
            onPressed: onBack ?? () => Navigator.of(context).maybePop(),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: InkWell(
              onTap: onTitleTap,
              child: Row(
                children: [
                  if (isGroup && avatar == null)
                    Container(
                      width: 32,
                      height: 32,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: t.surfaceAlt,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: t.border),
                      ),
                      child:
                          Icon(Icons.group_outlined, size: 16, color: t.textMuted),
                    )
                  else
                    AvatarImage(name: name, descriptor: avatar, size: 32),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w500,
                                  color: t.text,
                                ),
                              ),
                            ),
                            if (verified) ...[
                              const SizedBox(width: 6),
                              Icon(Icons.shield_outlined, size: 12, color: t.accent),
                            ],
                          ],
                        ),
                        if (sub != null)
                          Text(
                            sub!,
                            style: monoStyle(
                              fontSize: 10,
                              color: t.textMuted,
                              letterSpacing: 0.3,
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (onVideoCall != null)
            IconButton(
              key: const ValueKey('chat-video-call-button'),
              icon: Icon(Icons.videocam_outlined, color: t.text),
              iconSize: 22,
              padding: const EdgeInsets.all(4),
              constraints: const BoxConstraints(),
              tooltip: 'Video call',
              onPressed: onVideoCall,
            ),
          if (onCall != null)
            IconButton(
              key: const ValueKey('chat-call-button'),
              icon: Icon(Icons.call, color: t.text),
              iconSize: 20,
              padding: const EdgeInsets.all(4),
              constraints: const BoxConstraints(),
              tooltip: 'Voice call',
              onPressed: onCall,
            ),
          if (menuActions.isEmpty)
            IconButton(
              icon: Icon(Icons.more_vert, color: t.textFaint),
              iconSize: 20,
              padding: const EdgeInsets.all(4),
              constraints: const BoxConstraints(),
              onPressed: null,
            )
          else
            PopupMenuButton<String>(
              icon: Icon(Icons.more_vert, color: t.textMuted),
              iconSize: 20,
              padding: const EdgeInsets.all(4),
              color: t.surface,
              onSelected: (label) => menuActions[label]?.call(),
              itemBuilder: (context) => [
                for (final label in menuActions.keys)
                  PopupMenuItem<String>(
                    value: label,
                    child: Text(
                      label,
                      style: TextStyle(fontSize: 13, color: t.text),
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}
