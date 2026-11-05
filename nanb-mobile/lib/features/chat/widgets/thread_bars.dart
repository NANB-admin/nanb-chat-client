import 'package:flutter/material.dart';

import '../../../app/design_tokens.dart';
import '../../../app/theme.dart';

/// Bars and banners that sit above the composer / under the top bar in the
/// chat thread. All are pure presentational widgets driven by [DesignTokens]
/// and callbacks — extracted from `chat_thread_screen.dart` to keep that file
/// focused on the screen's state/logic.

/// The "Replying to …" preview shown above the composer while composing a reply.
class ReplyComposerBanner extends StatelessWidget {
  const ReplyComposerBanner({
    super.key,
    required this.t,
    required this.sender,
    required this.preview,
    required this.onCancel,
  });
  final DesignTokens t;
  final String sender;
  final String preview;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      decoration: BoxDecoration(
        color: t.surface,
        border: Border(top: BorderSide(color: t.border)),
      ),
      child: Row(
        children: [
          Container(width: 3, height: 34, color: t.accent),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Replying to $sender',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: t.accent,
                  ),
                ),
                Text(
                  preview,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: t.textMuted),
                ),
              ],
            ),
          ),
          IconButton(
            icon: Icon(Icons.close, size: 18, color: t.textMuted),
            onPressed: onCancel,
          ),
        ],
      ),
    );
  }
}

/// Accept/Reject bar shown instead of the composer for an inbound message
/// request (a sender the user never contacted).
class RequestBar extends StatelessWidget {
  const RequestBar({
    super.key,
    required this.t,
    required this.peerUsername,
    required this.onAccept,
    required this.onReject,
    required this.onReport,
  });

  final DesignTokens t;
  final String peerUsername;
  final VoidCallback onAccept;
  final VoidCallback onReject;

  /// Reports the sender to NANb AND rejects the request.
  final VoidCallback onReport;

  @override
  Widget build(BuildContext context) {
    final handle = peerUsername.startsWith('@')
        ? peerUsername
        : '@$peerUsername';
    final label = peerUsername == 'unknown'
        ? 'An unidentified sender wants to message you'
        : '$handle wants to message you';
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      decoration: BoxDecoration(
        color: t.surface,
        border: Border(top: BorderSide(color: t.border)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            label,
            textAlign: TextAlign.center,
            style: monoStyle(
              fontSize: 11.5,
              color: t.textMuted,
              letterSpacing: 0.3,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: FilledButton(
                  key: const ValueKey('request-accept'),
                  onPressed: onAccept,
                  style: FilledButton.styleFrom(
                    backgroundColor: t.accent,
                    foregroundColor: t.accentOn,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  child: Text(
                    'Accept',
                    style: monoStyle(
                      fontSize: 12,
                      color: t.accentOn,
                      letterSpacing: 0.4,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton(
                  key: const ValueKey('request-reject'),
                  onPressed: onReject,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: t.danger,
                    side: BorderSide(color: t.danger),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  child: Text(
                    'Reject',
                    style: monoStyle(
                      fontSize: 12,
                      color: t.danger,
                      letterSpacing: 0.4,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton(
                  key: const ValueKey('request-report'),
                  onPressed: onReport,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: t.danger,
                    backgroundColor: t.danger.withValues(alpha: 0.1),
                    side: BorderSide(color: t.danger),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  child: Text(
                    'Report',
                    style: monoStyle(
                      fontSize: 12,
                      color: t.danger,
                      letterSpacing: 0.4,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Accept/Reject bar shown instead of the composer when this device has been
/// added to a group it hasn't joined yet. Accept unlocks the chat (and syncs to
/// our other devices); Reject leaves the group and returns to the chat list.
class GroupInviteBar extends StatelessWidget {
  const GroupInviteBar({
    super.key,
    required this.t,
    required this.groupName,
    required this.onAccept,
    required this.onReject,
  });

  final DesignTokens t;
  final String? groupName;
  final VoidCallback onAccept;
  final VoidCallback onReject;

  @override
  Widget build(BuildContext context) {
    final name = (groupName ?? '').isEmpty ? 'a group' : '“$groupName”';
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      decoration: BoxDecoration(
        color: t.surface,
        border: Border(top: BorderSide(color: t.border)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'You were added to $name',
            textAlign: TextAlign.center,
            style: monoStyle(
              fontSize: 11.5,
              color: t.textMuted,
              letterSpacing: 0.3,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: onReject,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: t.danger,
                    side: BorderSide(color: t.danger),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  child: Text(
                    'Reject',
                    style: monoStyle(
                      fontSize: 12,
                      color: t.danger,
                      letterSpacing: 0.4,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton(
                  onPressed: onAccept,
                  style: FilledButton.styleFrom(
                    backgroundColor: t.accent,
                    foregroundColor: t.accentOn,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  child: Text(
                    'Accept',
                    style: monoStyle(
                      fontSize: 12,
                      color: t.accentOn,
                      letterSpacing: 0.4,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The in-chat search bar shown under the top bar while searching: a text
/// field, a live result count, and a close button. Results render in the
/// message list below (filtered to matches over the full local history).
class ThreadSearchBar extends StatelessWidget {
  const ThreadSearchBar({
    super.key,
    required this.t,
    required this.controller,
    required this.onChanged,
    required this.onClose,
    required this.resultCount,
    required this.hasQuery,
  });

  final DesignTokens t;
  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final VoidCallback onClose;
  final int resultCount;
  final bool hasQuery;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
      decoration: BoxDecoration(
        color: t.surface,
        border: Border(bottom: BorderSide(color: t.border)),
      ),
      child: Row(
        children: [
          Icon(Icons.search, size: 18, color: t.textMuted),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: controller,
              autofocus: true,
              onChanged: onChanged,
              style: TextStyle(fontSize: 14, color: t.text),
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
                hintText: 'Search messages',
                hintStyle: TextStyle(fontSize: 14, color: t.textFaint),
              ),
            ),
          ),
          if (hasQuery)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Text(
                '$resultCount',
                style: monoStyle(fontSize: 12, color: t.textMuted),
              ),
            ),
          IconButton(
            icon: Icon(Icons.close, size: 20, color: t.text),
            padding: const EdgeInsets.all(4),
            constraints: const BoxConstraints(),
            tooltip: 'Close search',
            onPressed: onClose,
          ),
        ],
      ),
    );
  }
}

/// The pinned-message banner under the top bar: a pin icon, "Pinned", and a
/// one-line preview of the conversation's single pinned message. Tapping it
/// jumps to the message; the × clears the pin (for everyone). Material →
/// tappable normally.
class PinnedBanner extends StatelessWidget {
  const PinnedBanner({
    super.key,
    required this.t,
    required this.preview,
    required this.onTap,
    required this.onClear,
  });
  final DesignTokens t;
  final String preview;
  final VoidCallback onTap;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: t.surface,
      child: InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: t.border)),
          ),
          child: Row(
            children: [
              Icon(Icons.push_pin, size: 15, color: t.accent),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Pinned',
                      style: monoStyle(
                        fontSize: 9.5,
                        color: t.accent,
                        letterSpacing: 0.3,
                      ),
                    ),
                    Text(
                      preview,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12.5, color: t.text),
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: Icon(Icons.close, size: 18, color: t.textMuted),
                padding: const EdgeInsets.all(6),
                constraints: const BoxConstraints(),
                tooltip: 'Unpin',
                onPressed: onClear,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Replaces the composer when the contact is blocked: a short note plus an
/// Unblock action. (Blocked threads are hidden from the chat list, so this is
/// mainly seen right after blocking from the contact profile.)
class BlockedBar extends StatelessWidget {
  const BlockedBar({super.key, required this.t, required this.onUnblock});

  final DesignTokens t;
  final VoidCallback onUnblock;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      decoration: BoxDecoration(
        color: t.surface,
        border: Border(top: BorderSide(color: t.border)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            "You blocked this contact. You won't receive their messages.",
            textAlign: TextAlign.center,
            style: monoStyle(
              fontSize: 11.5,
              color: t.textMuted,
              letterSpacing: 0.3,
            ),
          ),
          const SizedBox(height: 10),
          OutlinedButton(
            onPressed: onUnblock,
            style: OutlinedButton.styleFrom(
              foregroundColor: t.accent,
              side: BorderSide(color: t.accent),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            child: Text(
              'Unblock',
              style: monoStyle(
                fontSize: 12,
                color: t.accent,
                letterSpacing: 0.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
