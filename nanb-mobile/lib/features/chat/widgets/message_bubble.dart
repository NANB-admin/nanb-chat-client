import 'package:flutter/material.dart';

import '../../../app/design_tokens.dart';
import '../../../app/theme.dart';
import '../models/link_preview.dart';
import 'link_preview_card.dart';
import 'linkified_text.dart';
import 'open_link_dialog.dart';
import 'sender_name_label.dart';

/// Status of an outgoing message (matches the design's Bubble).
enum BubbleStatus { pending, sent, delivered, read }

class MessageBubble extends StatelessWidget {
  const MessageBubble({
    super.key,
    required this.text,
    required this.time,
    required this.mine,
    this.status,
    this.replyWho,
    this.replyText,
    this.tail = true,
    this.senderLabel,
    this.senderColor,
    this.highlight,
    this.onOpenLink,
    this.onTapReply,
    this.linkPreview,
  });

  final String text;
  final String time;
  final bool mine;
  final BubbleStatus? status;
  final String? replyWho;
  final String? replyText;
  final bool tail;
  final String? senderLabel;

  /// Color for [senderLabel] (group threads give each member their own). Falls
  /// back to the accent when null.
  final Color? senderColor;

  /// When non-empty, occurrences of this substring in [text] are highlighted
  /// (case-insensitive) — used to mark the matched term in search results.
  final String? highlight;

  /// Called with the address of a tapped link. Null → ask the user, then open it
  /// in the browser ([confirmAndOpenLink]).
  final ValueChanged<String>? onOpenLink;

  /// Called when the quoted reply preview above the bubble is tapped (the thread
  /// uses it to scroll to the original message). Null → the preview isn't
  /// tappable.
  final VoidCallback? onTapReply;

  /// Card for a link in [text] (title / description / thumbnail), shown above the
  /// text. Tapping it opens the link the same way tapping the link text does.
  final LinkPreview? linkPreview;

  @override
  Widget build(BuildContext context) {
    final t = DesignTokens.of(context);
    final bg = mine ? t.bubbleOut : t.bubbleIn;
    final fg = mine ? t.bubbleOutText : t.text;
    final tailRadius = mine
        ? const BorderRadius.only(
            topLeft: Radius.circular(14),
            topRight: Radius.circular(14),
            bottomLeft: Radius.circular(14),
            bottomRight: Radius.circular(4),
          )
        : const BorderRadius.only(
            topLeft: Radius.circular(14),
            topRight: Radius.circular(14),
            bottomRight: Radius.circular(14),
            bottomLeft: Radius.circular(4),
          );
    final radius = tail ? tailRadius : BorderRadius.circular(14);

    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstraintsTransformBox(
        constraintsTransform: (c) => c.copyWith(
          maxWidth: MediaQuery.of(context).size.width * 0.78,
        ),
        child: Column(
          crossAxisAlignment:
              mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            if (senderLabel != null && !mine)
              SenderNameLabel(
                label: senderLabel!,
                color: senderColor ?? t.accent,
              ),
            if (replyWho != null && replyText != null)
              _ReplyPreview(
                who: replyWho!,
                text: replyText!,
                t: t,
                onTap: onTapReply,
              ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: bg,
                borderRadius: radius,
                border: mine ? null : Border.all(color: t.bubbleInBorder),
              ),
              child: _bubbleContent(context, fg),
            ),
            const SizedBox(height: 2),
            _TimeLine(time: time, mine: mine, status: status, t: t),
          ],
        ),
      ),
    );
  }

  /// The preview card (when there is one) stacked above the message text.
  Widget _bubbleContent(BuildContext context, Color fg) {
    final preview = linkPreview;
    final text = _buildText(context, fg);
    if (preview == null) return text;
    final open = onOpenLink ?? (url) => confirmAndOpenLink(context, url);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LinkPreviewCard(
          preview: preview,
          color: fg,
          onTap: () => open(preview.url),
        ),
        text,
      ],
    );
  }

  /// The bubble body. Normally the text with its web links tappable; when
  /// [highlight] is set (search results), the matched (case-insensitive) runs
  /// are drawn on an amber highlight + bold so the search term stands out on
  /// either bubble colour — and links are left alone there, since a tap on a
  /// search result jumps to the message instead.
  Widget _buildText(BuildContext context, Color fg) {
    final base = TextStyle(fontSize: 14, color: fg, height: 1.4);
    final q = highlight;
    if (q == null || q.isEmpty) {
      return LinkifiedText(
        text: text,
        style: base,
        onOpenLink: onOpenLink ?? (url) => confirmAndOpenLink(context, url),
      );
    }
    final lcText = text.toLowerCase();
    final lcQ = q.toLowerCase();
    final spans = <TextSpan>[];
    var start = 0;
    while (true) {
      final idx = lcText.indexOf(lcQ, start);
      if (idx < 0) {
        if (start < text.length) spans.add(TextSpan(text: text.substring(start)));
        break;
      }
      if (idx > start) spans.add(TextSpan(text: text.substring(start, idx)));
      spans.add(TextSpan(
        text: text.substring(idx, idx + q.length),
        style: const TextStyle(
          backgroundColor: Color(0x80FFD54F),
          fontWeight: FontWeight.bold,
        ),
      ));
      start = idx + q.length;
    }
    return Text.rich(TextSpan(style: base, children: spans));
  }
}

class _ReplyPreview extends StatelessWidget {
  const _ReplyPreview({
    required this.who,
    required this.text,
    required this.t,
    this.onTap,
  });
  final String who;
  final String text;
  final DesignTokens t;

  /// Tapping the chip (jump to the quoted message). Null → not tappable.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    // NOTE: deliberately a uniform borderRadius + a separate accent strip
    // (not a left-only BorderSide with top-only corners). Impeller on Android
    // mis-renders an asymmetric border + asymmetric borderRadius combo as a
    // solid filled block.
    //
    // This chip sits ABOVE the bubble on the page background, not inside it, so
    // it must be coloured from the page palette (surfaceAlt / textMuted) for
    // both mine and incoming. Never reuse bubbleOutText here: in light mode it
    // is page-coloured (near-white), which renders invisible on the page bg.
    final chip = ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: Container(
        margin: const EdgeInsets.only(bottom: 2),
        color: t.surfaceAlt,
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(width: 3, color: t.accent),
              Flexible(
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        who,
                        style: monoStyle(
                          fontSize: 10,
                          color: t.textMuted.withValues(alpha: 0.7),
                        ),
                      ),
                      Text(
                        text,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: t.textMuted,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (onTap == null) return chip;
    // Opaque so the whole chip (not just its text) is the tap target; a
    // long-press still reaches the bubble's own actions menu.
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: chip,
    );
  }
}

class _TimeLine extends StatelessWidget {
  const _TimeLine({
    required this.time,
    required this.mine,
    required this.status,
    required this.t,
  });
  final String time;
  final bool mine;
  final BubbleStatus? status;
  final DesignTokens t;

  IconData? _statusIcon() {
    if (!mine || status == null) return null;
    switch (status!) {
      case BubbleStatus.pending:
        return Icons.schedule;
      case BubbleStatus.sent:
        return Icons.check;
      case BubbleStatus.delivered:
        return Icons.done_all;
      case BubbleStatus.read:
        return Icons.done_all;
    }
  }

  Color _statusColor() {
    if (status == BubbleStatus.read) return t.accent;
    return t.textFaint;
  }

  @override
  Widget build(BuildContext context) {
    final icon = _statusIcon();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            time,
            style: monoStyle(
              fontSize: 9.5,
              color: t.textFaint,
              letterSpacing: 0.3,
            ),
          ),
          if (icon != null) ...[
            const SizedBox(width: 4),
            Icon(icon, size: 11, color: _statusColor()),
          ],
        ],
      ),
    );
  }
}
