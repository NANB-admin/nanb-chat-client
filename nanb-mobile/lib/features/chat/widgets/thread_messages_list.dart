import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gal/gal.dart';

import '../../../app/design_tokens.dart';
import '../../../app/theme.dart';
import '../../../core/platform/ephemeral_clipboard.dart';
import '../conversations_notifier.dart';
import '../file_opener.dart';
import '../media_file_opener.dart';
import '../models/chat_message.dart';
import '../services/message_edit_service.dart';
import '../services/sticker_marker.dart';
import '../services/temp_media_store.dart';
import '../models/conversation.dart';
import '../models/conversation_kind.dart';
import '../models/group_member.dart';
import '../models/message_kind.dart';
import '../models/system_event.dart';
import 'forward_sheet.dart';
import 'chat_atoms.dart';
import 'message_bubble.dart';
import 'sender_name_label.dart';
import 'message_info_sheet.dart';
import 'message_bubble_file.dart';
import 'reaction_chips.dart';
import 'sticker_bubble.dart';
import 'confirm_message_delete_dialog.dart';
import 'view_once_bubble.dart';
import 'view_once_viewer.dart';
import 'typing_bubble.dart';
import 'thread_media_bubbles.dart';

/// One rendered entry in the virtualized thread list. The whole thread is
/// flattened, oldest → newest, into a `List<_ThreadRow>` ONCE per message set
/// (see [_MessagesListState._rebuildRowsIfNeeded]); the [ListView.builder]'s
/// `itemBuilder` then maps a single index to a single row, so only the bubbles
/// actually on screen ever build a widget — and the per-message work that used
/// to run for every row on every rebuild ([SystemEvent.tryDecode], the group
/// sender lookup) is precomputed here instead.
sealed class _ThreadRow {
  const _ThreadRow();
}

/// A day-separator header ("TODAY" / "12/3/2026") that precedes the first
/// bubble of each calendar day.
class _DaySeparatorRow extends _ThreadRow {
  const _DaySeparatorRow(this.label);
  final String label;
}

/// A system event rendered as a centered pill (join/leave/rename …). The event
/// is decoded to its display text once, here, rather than per scroll frame.
class _SystemRow extends _ThreadRow {
  const _SystemRow(this.message, this.text);
  final ChatMessage message;
  final String text;
}

/// A text/media message bubble. [senderLabel] is precomputed for group threads
/// (only at the first bubble of a same-sender run); it is null otherwise.
class _MessageRow extends _ThreadRow {
  const _MessageRow(this.message, this.senderLabel, this.senderKey);
  final ChatMessage message;
  final String? senderLabel;

  /// Stable identity (account id, else device id) the sender's color derives
  /// from. Null whenever [senderLabel] is.
  final String? senderKey;
}

/// The scrolling message list for the chat thread: day separators, system
/// lines, text/media bubbles (with reactions), the long-press actions sheet,
/// and the per-message helpers (download/forward/retry/save). Extracted from
/// `chat_thread_screen.dart`.
class MessagesList extends StatefulWidget {
  const MessagesList({
    super.key,
    required this.messages,
    required this.hasMoreOlderMessages,
    required this.scrollController,
    required this.t,
    required this.notifier,
    required this.isGroup,
    required this.members,
    required this.onReply,
    required this.messageKeys,
    this.onAddToStickers,
    this.highlightQuery,
    this.onTapMessage,
    this.flashEnvelopeId,
    this.onJumpToMessageId,
    this.peerTyping = false,
    this.onEdit,
  });
  final List<ChatMessage> messages;
  final bool hasMoreOlderMessages;
  final ScrollController scrollController;
  final DesignTokens t;
  final ConversationsNotifier notifier;
  final bool isGroup;
  final List<GroupMember> members;

  /// Invoked when the user picks "Reply" from a message's long-press menu.
  final ValueChanged<ChatMessage> onReply;

  /// Invoked when the user picks "Add to stickers" on an image. Null hides the
  /// action (e.g. in search results).
  final ValueChanged<ChatMessage>? onAddToStickers;

  /// Stable per-envelope keys (owned by the screen) for `ensureVisible`. Keys
  /// are attached only in the full thread (not in the search-results view).
  final Map<String, GlobalKey> messageKeys;

  /// Search mode: the term to highlight in text bubbles (null = full thread).
  final String? highlightQuery;

  /// Search mode: tapping a result jumps to it (null = full thread, no jump).
  final ValueChanged<ChatMessage>? onTapMessage;

  /// Full thread: the message id to flash-highlight after a jump-to.
  final String? flashEnvelopeId;

  /// Full thread: tapping a reply's quoted preview jumps to the original
  /// message (by envelope id). Null → the preview isn't tappable.
  final ValueChanged<String>? onJumpToMessageId;

  /// Full thread: the peer is composing — a typing bubble sits at the bottom.
  final bool peerTyping;

  /// Invoked when the user picks "Edit" on one of their own recent text
  /// messages. Null hides the action (e.g. in search results).
  final ValueChanged<ChatMessage>? onEdit;

  @override
  State<MessagesList> createState() => _MessagesListState();
}

class _MessagesListState extends State<MessagesList> {
  /// Flattened thread rows, oldest → newest. Rebuilt only when the inputs that
  /// shape it change (see [_rebuildRowsIfNeeded]) — NOT on a status-tick /
  /// typing / connection-pulse rebuild, and NOT per scroll frame.
  List<_ThreadRow> _rows = const <_ThreadRow>[];

  // The inputs the current [_rows] were built from. Reference-compared so an
  // unchanged message set reuses the model instead of re-walking every message.
  List<ChatMessage>? _builtFromMessages;
  List<GroupMember>? _builtFromMembers;
  bool? _builtFromIsGroup;

  bool get _searching => widget.onTapMessage != null;

  @override
  void initState() {
    super.initState();
    _rebuildRowsIfNeeded();
  }

  @override
  void didUpdateWidget(MessagesList old) {
    super.didUpdateWidget(old);
    _rebuildRowsIfNeeded();
  }

  void _rebuildRowsIfNeeded() {
    if (identical(_builtFromMessages, widget.messages) &&
        identical(_builtFromMembers, widget.members) &&
        _builtFromIsGroup == widget.isGroup) {
      return;
    }
    _builtFromMessages = widget.messages;
    _builtFromMembers = widget.members;
    _builtFromIsGroup = widget.isGroup;
    _rows = _buildRows(widget.messages, widget.isGroup, widget.members);
  }

  /// Walk the message set once, oldest → newest, emitting the flat row model:
  /// a day separator before each new calendar day, a system pill for system
  /// events, and a bubble row (with a precomputed group sender label) for
  /// everything else. Runs once per message set, not per scroll frame.
  static List<_ThreadRow> _buildRows(
    List<ChatMessage> messages,
    bool isGroup,
    List<GroupMember> members,
  ) {
    // O(1) sender lookup, built once per message set rather than a per-bubble
    // `members.firstWhere`. First match wins, matching the old lookup.
    final memberByDevice = <String, GroupMember>{};
    if (isGroup) {
      for (final mm in members) {
        memberByDevice.putIfAbsent(mm.deviceId, () => mm);
      }
    }

    final rows = <_ThreadRow>[];
    DateTime? lastDay;
    for (var i = 0; i < messages.length; i++) {
      final m = messages[i];
      final day = DateTime(m.serverTs.year, m.serverTs.month, m.serverTs.day);

      // 1. System events: pill, not bubble.
      if (m.kind == MessageKind.system) {
        final ev = SystemEvent.tryDecode(m.body);
        final text = ev?.displayText ?? '(unknown event)';
        if (lastDay != day) {
          rows.add(_DaySeparatorRow(_dayLabel(day)));
          lastDay = day;
        }
        rows.add(_SystemRow(m, text));
        continue;
      }

      // 2. Day separator (unchanged).
      if (lastDay != day) {
        rows.add(_DaySeparatorRow(_dayLabel(day)));
        lastDay = day;
      }

      // 3. Compute sender label for group thread, with run-grouping.
      String? senderLabel;
      String? senderKey;
      if (isGroup && !m.mine) {
        final prev = i > 0 ? messages[i - 1] : null;
        final samePriorSender = prev != null &&
            prev.senderDeviceId == m.senderDeviceId &&
            prev.kind != MessageKind.system;
        if (!samePriorSender) {
          final member = memberByDevice[m.senderDeviceId];
          senderLabel = member?.username ?? m.senderDeviceId;
          senderKey = member?.accountId ?? m.senderDeviceId;
        }
      }

      rows.add(_MessageRow(m, senderLabel, senderKey));
    }
    return rows;
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.t;
    if (widget.messages.isEmpty) {
      // While searching, the empty state means "type a query" / "no matches",
      // not the first-run encryption hint.
      if (_searching) {
        final hasQuery = (widget.highlightQuery ?? '').isNotEmpty;
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Text(
              hasQuery ? 'No messages match.' : 'Type to search this chat.',
              textAlign: TextAlign.center,
              style: monoStyle(fontSize: 12, color: t.textMuted),
            ),
          ),
        );
      }
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.lock_outline, color: t.accent),
              const SizedBox(height: 12),
              Text(
                'Encrypted with end-to-end keys generated on this device.',
                textAlign: TextAlign.center,
                style: monoStyle(fontSize: 11, color: t.textMuted),
              ),
              const SizedBox(height: 8),
              Text(
                'Send the first message to start.',
                style: TextStyle(color: t.textFaint, fontSize: 12),
              ),
            ],
          ),
        ),
      );
    }

    // The row model is oldest → newest; render it into a `reverse: true`
    // ListView so child index 0 sits at the visual bottom (the NEWEST message).
    //
    // Why reverse:true: prepending older messages to `messages` (during
    // pagination) extends the array at the visual TOP without disturbing the
    // user's scroll anchor (which is measured from the bottom).
    //
    // ListView.builder (not a `children:` list) so only the bubbles actually on
    // screen build — the loaded window can grow to thousands of messages while
    // the work stays proportional to what's visible.
    final rowCount = _rows.length;
    // The "loading older" cue is a virtual extra item pinned to the OLDEST
    // (top) end — the LARGEST index, which with reverse:true is the visual top,
    // where the scroll prefetch fires. Appending it at the bottom (below the
    // newest message) is where it would never auto-load. The screen's scroll
    // listener does the actual fetch; this is just a cue.
    final showLoadOlder = widget.hasMoreOlderMessages;
    // The typing bubble is index 0 (the visual bottom, under the newest
    // message), so every row index is shifted by [lead].
    final showTyping = widget.peerTyping && !_searching;
    final lead = showTyping ? 1 : 0;
    final itemCount = lead + rowCount + (showLoadOlder ? 1 : 0);

    return ListView.builder(
      controller: widget.scrollController,
      reverse: true,
      // Drag the message list to dismiss the keyboard. On iOS the composer's
      // multiline field shows a newline key (not a "Done" key), and iPhones
      // have no hardware Back — so without this the only way to hide the
      // keyboard was to leave the thread. Swiping the messages now closes it
      // (the iMessage/WhatsApp gesture).
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      itemCount: itemCount,
      itemBuilder: (context, index) {
        if (showLoadOlder && index == itemCount - 1) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Center(
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          );
        }
        // reverse:true → index 0 is the visual bottom (newest). Map it back
        // onto the oldest → newest row model from the end.
        if (showTyping && index == 0) return const TypingBubble();
        final row = _rows[rowCount - 1 - (index - lead)];
        return _buildRow(context, row);
      },
    );
  }

  Widget _buildRow(BuildContext context, _ThreadRow row) {
    switch (row) {
      case _DaySeparatorRow():
        // The separator carries the 4px gap the old flat list emitted as a
        // trailing SizedBox — same vertical layout, one list item.
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DaySeparator(label: row.label),
            const SizedBox(height: 4),
          ],
        );
      case _SystemRow():
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: SystemLine(text: row.text),
        );
      case _MessageRow():
        return _buildMessageRow(
            context, row.message, row.senderLabel, row.senderKey);
    }
  }

  /// Builds a single text/media bubble row: the bubble itself, the forwarded
  /// marker, media status overlay, reaction chips, the flash/key wrapper, and
  /// the swipe-to-reply Dismissible. Only invoked for on-screen rows.
  /// Tap handler for [m]'s quoted-reply chip, or null when there's nothing to
  /// jump to (not a reply, or jumping is disabled, e.g. in search results).
  VoidCallback? _replyJumpFor(ChatMessage m) {
    final jump = widget.onJumpToMessageId;
    final target = m.replyToEnvelopeId;
    if (jump == null || target == null) return null;
    return () => jump(target);
  }

  Widget _buildMessageRow(
    BuildContext context,
    ChatMessage m,
    String? senderLabel,
    String? senderKey,
  ) {
    final t = widget.t;
    final senderColor = senderKey == null
        ? null
        : senderColorFor(senderKey, Theme.of(context).brightness);

    // Render bubble.
    Widget bubble;
    if (m.viewOnce) {
      bubble = ViewOnceBubble(
        message: m,
        time: _hhmm(m.serverTs),
        onOpen: _canOpenViewOnce(m) ? () => _openViewOnce(context, m) : null,
        onRetry: m.failed ? () => _retryFailedSend(context, m) : null,
      );
    } else if (StickerMarker.isSticker(m)) {
      bubble = StickerBubbleAsync(message: m, notifier: widget.notifier);
    } else if (m.kind == MessageKind.image) {
      bubble = ImageBubbleAsync(message: m, notifier: widget.notifier);
    } else if (m.kind == MessageKind.file) {
      bubble = MessageBubbleFile(
        filename: m.mediaFilename ?? 'attachment',
        size: _humanSize(m.mediaSize ?? 0),
        time: _hhmm(m.serverTs),
        mine: m.mine,
        caption: m.body,
        onTap: m.uploading ? null : () => _downloadFile(context, m),
      );
    } else if (m.kind == MessageKind.video) {
      bubble = VideoBubbleAsync(message: m, notifier: widget.notifier);
    } else if (m.kind == MessageKind.voice) {
      bubble = VoiceBubble(message: m, notifier: widget.notifier);
    } else {
      bubble = MessageBubble(
        text: m.body,
        time: m.edited ? 'edited · ${_hhmm(m.serverTs)}' : _hhmm(m.serverTs),
        mine: m.mine,
        senderLabel: senderLabel,
        senderColor: senderColor,
        replyWho: m.replyToSender,
        replyText: m.replyToPreview,
        status: m.mine ? _outgoingBubbleStatus(m) : null,
        highlight: widget.highlightQuery,
        onTapReply: _replyJumpFor(m),
        linkPreview: m.linkPreview,
      );
    }
    // Media bubbles don't draw the sender's name themselves (the text bubble
    // does), so add it above them — otherwise a photo in a group has no author.
    if (senderLabel != null && m.kind != MessageKind.text) {
      bubble = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          SenderNameLabel(
            label: senderLabel,
            color: senderColor ?? t.accent,
          ),
          bubble,
        ],
      );
    }
    // Forwarded marker — a small tag above the bubble, aligned with it.
    if (m.forwarded) {
      bubble = Column(
        crossAxisAlignment:
            m.mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 2),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.forward, size: 11, color: t.textFaint),
                const SizedBox(width: 3),
                Text(
                  'Forwarded',
                  style: monoStyle(
                    fontSize: 9.5,
                    color: t.textFaint,
                    letterSpacing: 0.3,
                  ).copyWith(fontStyle: FontStyle.italic),
                ),
              ],
            ),
          ),
          bubble,
        ],
      );
    }
    // Media bubbles (image/video/voice/file) carry no inline tick like the
    // text bubble's status row, so MY media messages get the sent/delivered/
    // read tick — plus the upload spinner / retry chip — overlaid at the
    // corner. Text draws its own status row; system messages have no status.
    final isMedia = m.kind == MessageKind.image ||
        m.kind == MessageKind.video ||
        m.kind == MessageKind.voice ||
        m.kind == MessageKind.file;
    if (m.mine && isMedia && !m.viewOnce) {
      bubble = MediaBubbleStatusWrap(
        uploading: m.uploading,
        failed: m.failed,
        onRetry: m.failed ? () => _retryFailedSend(context, m) : null,
        status: _outgoingBubbleStatus(m),
        readColor: t.accent,
        faintColor: t.textFaint,
        child: bubble,
      );
    }
    // Reaction chips beneath the bubble, aligned to the bubble's side.
    // Tapping a chip toggles the user's own reaction with that emoji.
    if (m.reactions.isNotEmpty) {
      bubble = Column(
        crossAxisAlignment:
            m.mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          bubble,
          Padding(
            padding: const EdgeInsets.only(top: 3, left: 4, right: 4),
            child: ReactionChips(
              reactions: m.reactions,
              myAccountId: widget.notifier.myAccountId,
              alignEnd: m.mine,
              onTapEmoji: (emoji) => widget.notifier.react(
                conversationId: m.conversationId,
                targetEnvelopeId: m.envelopeId,
                emoji: emoji,
              ),
            ),
          ),
        ],
      );
    }
    // Full thread only: a stable key (so a search-result tap can scroll here)
    // and a brief flash after such a jump. Search mode attaches neither.
    final keyable = !_searching && m.envelopeId.isNotEmpty;
    final flashing = keyable && widget.flashEnvelopeId == m.envelopeId;
    final messageRow = AnimatedContainer(
      key: keyable
          ? widget.messageKeys.putIfAbsent(m.envelopeId, () => GlobalKey())
          : null,
      duration: const Duration(milliseconds: 350),
      padding: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        color: flashing ? t.accent.withValues(alpha: 0.24) : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
      ),
      child: GestureDetector(
        onLongPress: () => _showMessageActions(context, m),
        // Search mode: tap a result to jump to it in the full thread.
        onTap: widget.onTapMessage == null
            ? null
            : () => widget.onTapMessage!(m),
        child: bubble,
      ),
    );
    // Swipe a bubble to the right to reply to it (snaps back — it's a reply
    // gesture, not a dismiss). System lines aren't replyable (they never reach
    // this builder).
    return Dismissible(
      key: ValueKey(
        'reply-${m.envelopeId.isNotEmpty ? m.envelopeId : m.outboxId}',
      ),
      direction: DismissDirection.startToEnd,
      dismissThresholds: const {DismissDirection.startToEnd: 0.28},
      confirmDismiss: (_) async {
        widget.onReply(m);
        return false;
      },
      background: Padding(
        padding: const EdgeInsets.only(left: 24),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Icon(Icons.reply, size: 22, color: t.textMuted),
        ),
      ),
      child: messageRow,
    );
  }

  static String _dayLabel(DateTime d) {
    final today = DateTime.now();
    final t0 = DateTime(today.year, today.month, today.day);
    if (d == t0) return 'Today';
    final yesterday = t0.subtract(const Duration(days: 1));
    if (d == yesterday) return 'Yesterday';
    return '${d.month}/${d.day}/${d.year}';
  }

  static String _hhmm(DateTime ts) {
    final l = ts.toLocal();
    final hh = l.hour.toString().padLeft(2, '0');
    final mm = l.minute.toString().padLeft(2, '0');
    return '$hh:$mm';
  }

  /// Maps a sent-message's [MessageDeliveryStatus] to the bubble's tick state:
  /// sent → single ✓, delivered → ✓✓, read → ✓✓ (accent-colored).
  static BubbleStatus _bubbleStatusFor(MessageDeliveryStatus s) {
    switch (s) {
      case MessageDeliveryStatus.sent:
        return BubbleStatus.sent;
      case MessageDeliveryStatus.delivered:
        return BubbleStatus.delivered;
      case MessageDeliveryStatus.read:
        return BubbleStatus.read;
    }
  }

  /// Tick state for one of MY outgoing messages — OPTIMISTIC: a queued send
  /// shows a single ✓ the instant it's on screen, rather than a clock that
  /// waits on the server round-trip. It reconciles to the real
  /// sent/delivered/read once the server acks (`outboxId` cleared), and a send
  /// that ultimately errors is surfaced by the failed overlay (which also takes
  /// over the tick here). Upload-in-flight legitimately isn't sent yet, so it
  /// keeps the plain clock.
  static BubbleStatus _outgoingBubbleStatus(ChatMessage m) {
    if (m.uploading || m.failed) return BubbleStatus.pending;
    final acked = m.outboxId == null || m.outboxId!.isEmpty;
    return acked ? _bubbleStatusFor(m.deliveryStatus) : BubbleStatus.sent;
  }

  static String _humanSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }

  /// Long-press menu for a message: retry (if failed), delete for me, and —
  /// The recipient's unopened copy, on a device that can show it. The web client
  /// can't play video or voice, so those stay closed there rather than be spent.
  bool _canOpenViewOnce(ChatMessage m) =>
      !m.mine &&
      m.viewOnceOpenedAt == null &&
      !(kIsWeb && (m.kind == MessageKind.video || m.kind == MessageKind.voice));

  Future<void> _openViewOnce(BuildContext context, ChatMessage m) async {
    final content =
        await widget.notifier.openViewOnce(m.conversationId, m.envelopeId);
    if (!context.mounted) return;
    if (content == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Couldn't open it. Try again.")),
      );
      return;
    }
    await ViewOnceViewer.open(context, content);
  }

  /// for your own already-sent messages — delete for everyone (unsend).
  void _showMessageActions(BuildContext context, ChatMessage m) {
    if (m.kind == MessageKind.system) return;
    final reachedServer = m.outboxId == null || m.outboxId!.isEmpty;
    final canUnsend = m.mine && !m.failed && reachedServer;
    // The author blocks forwarding (1:1 peer flag) → their messages lose
    // Forward AND Copy here (copy would be a trivial bypass for text).
    // Your own messages are always yours to forward/copy.
    final convo = widget.notifier.byId(m.conversationId);
    final authorBlocksForwarding =
        !m.mine &&
        convo != null &&
        convo.kind == ConversationKind.oneToOne &&
        convo.peerBlocksForwarding;
    // A view-once message can only be opened (by tapping it) or deleted.
    final viewOnce = m.viewOnce;
    final canCopy =
        !viewOnce &&
        m.kind == MessageKind.text &&
        m.body.isNotEmpty &&
        !authorBlocksForwarding;
    final canForward =
        !viewOnce && !m.failed && !m.uploading && !authorBlocksForwarding;
    final canSaveToGallery =
        !viewOnce &&
        !m.uploading &&
        !m.failed &&
        (m.kind == MessageKind.image || m.kind == MessageKind.video);
    // Same bypass guard as Forward/Copy: an author who blocks forwarding doesn't
    // get their images collected into someone else's stickers either.
    final canAddToStickers = widget.onAddToStickers != null &&
        !viewOnce &&
        m.kind == MessageKind.image &&
        !m.uploading &&
        !m.failed &&
        !authorBlocksForwarding;
    // Reactions target a server-acked message (the reaction control names its
    // envelope id), so only offer them once the message has a real id.
    final canReact =
        !viewOnce && m.envelopeId.isNotEmpty && !m.failed && reachedServer;
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (canReact) ...[
              ReactionPickerRow(
                selectedEmoji: widget.notifier.myAccountId.isEmpty
                    ? null
                    : m.reactions[widget.notifier.myAccountId],
                onPick: (emoji) {
                  Navigator.pop(sheetContext);
                  widget.notifier.react(
                    conversationId: m.conversationId,
                    targetEnvelopeId: m.envelopeId,
                    emoji: emoji,
                  );
                },
              ),
              const Divider(height: 1),
            ],
            if (m.failed)
              ListTile(
                leading: const Icon(Icons.refresh),
                title: const Text('Retry'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _retryFailedSend(context, m);
                },
              ),
            if (!viewOnce)
            ListTile(
              leading: const Icon(Icons.reply),
              title: const Text('Reply'),
              onTap: () {
                Navigator.pop(sheetContext);
                widget.onReply(m);
              },
            ),
            if (!viewOnce && m.envelopeId.isNotEmpty && !m.failed && reachedServer)
              Builder(builder: (_) {
                final isPinned = convo?.pinnedEnvelopeId == m.envelopeId;
                final hasOtherPin =
                    convo?.pinnedEnvelopeId != null && !isPinned;
                return ListTile(
                  leading: Icon(
                      isPinned ? Icons.push_pin : Icons.push_pin_outlined),
                  title: Text(isPinned ? 'Unpin' : 'Pin'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    if (isPinned) {
                      widget.notifier.setConversationPin(m.conversationId, null);
                    } else if (hasOtherPin) {
                      // One pin per chat — block the second and tell the user.
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text(
                            'Only one pinned message per chat — unpin the current one first.',
                          ),
                        ),
                      );
                    } else {
                      widget.notifier.setConversationPin(
                          m.conversationId, m.envelopeId);
                    }
                  },
                );
              }),
            if (m.mine && !widget.isGroup && !m.failed && reachedServer)
              ListTile(
                leading: const Icon(Icons.info_outline),
                title: const Text('Info'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  MessageInfoSheet.show(context, m);
                },
              ),
            if (!viewOnce &&
                widget.onEdit != null &&
                MessageEditService.canEdit(m))
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: const Text('Edit'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  widget.onEdit!(m);
                },
              ),
            if (canCopy)
              ListTile(
                leading: const Icon(Icons.copy_outlined),
                title: const Text('Copy'),
                onTap: () async {
                  Navigator.pop(sheetContext);
                  // E2EE content shouldn't linger in the shared clipboard /
                  // keyboard history — auto-clear it after a minute.
                  await copyEphemeral(m.body);
                  if (context.mounted) {
                    ScaffoldMessenger.of(
                      context,
                    ).showSnackBar(const SnackBar(content: Text('Copied')));
                  }
                },
              ),
            if (canForward)
              ListTile(
                leading: const Icon(Icons.forward),
                title: const Text('Forward'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _showForwardPicker(context, m);
                },
              ),
            if (canSaveToGallery)
              ListTile(
                leading: const Icon(Icons.download_outlined),
                title: const Text('Save to gallery'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _saveToGallery(context, m);
                },
              ),
            if (canAddToStickers)
              ListTile(
                leading: const Icon(Icons.sticky_note_2_outlined),
                title: const Text('Add to stickers'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  widget.onAddToStickers!(m);
                },
              ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Delete for me'),
              onTap: () async {
                Navigator.pop(sheetContext);
                if (!await confirmMessageDelete(context, forEveryone: false)) {
                  return;
                }
                await widget.notifier.deleteMessageForMe(m.conversationId, m);
              },
            ),
            if (canUnsend)
              ListTile(
                leading: const Icon(Icons.delete_forever),
                title: const Text('Delete for everyone'),
                onTap: () async {
                  Navigator.pop(sheetContext);
                  if (!await confirmMessageDelete(context, forEveryone: true)) {
                    return;
                  }
                  await widget.notifier.unsendMessage(
                    conversationId: m.conversationId,
                    target: m,
                  );
                },
              ),
          ],
        ),
        ),
      ),
    );
  }

  /// "Forward to…" picker: every other active conversation (requests and
  /// groups you were removed from are excluded). The user ticks one or more,
  /// then the message is re-sent to each via
  /// [ConversationsNotifier.forwardMessage].
  Future<void> _showForwardPicker(BuildContext context, ChatMessage m) async {
    final targets = widget.notifier.conversations
        .where(
          (c) =>
              c.id != m.conversationId &&
              !c.pending &&
              (c.kind == ConversationKind.group
                  ? c.members.any((mm) => mm.isSelf)
                  : c.peerAccountId.isNotEmpty),
        )
        .toList(growable: false);
    if (targets.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No other conversations to forward to.')),
      );
      return;
    }
    final chosen = await ForwardSheet.show(
      context,
      notifier: widget.notifier,
      targets: targets,
    );
    if (chosen == null || chosen.isEmpty || !context.mounted) return;
    await _forwardToAll(context, m, chosen);
  }

  Future<void> _forwardToAll(
    BuildContext context,
    ChatMessage m,
    List<Conversation> targets,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    var ok = 0;
    for (final target in targets) {
      try {
        if (await widget.notifier
            .forwardMessage(source: m, targetConversationId: target.id)) {
          ok++;
        }
      } catch (_) {/* counted as a failure below */}
    }
    final String text;
    if (ok == targets.length) {
      text = targets.length == 1
          ? 'Forwarded to ${widget.notifier.displayNameFor(targets.first)}'
          : 'Forwarded to $ok chats';
    } else if (ok == 0) {
      text = 'Couldn’t forward — try again.';
    } else {
      text = 'Forwarded to $ok of ${targets.length} chats.';
    }
    messenger.showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _retryFailedSend(BuildContext context, ChatMessage m) async {
    // Acknowledge the tap immediately — the retry chip is small and easy to
    // miss as a press, so confirm with haptics + a transient toast before the
    // (async) resend runs.
    HapticFeedback.mediumImpact();
    final messenger = ScaffoldMessenger.of(context);
    final outboxId = m.outboxId;
    if (outboxId == null || outboxId.isEmpty) return;
    messenger.showSnackBar(
      const SnackBar(
        content: Text('Resending…'),
        duration: Duration(milliseconds: 900),
      ),
    );
    // Text carries its own payload — re-send directly. Media needs the cached
    // plaintext bytes, which may have been evicted.
    if (m.kind == MessageKind.text) {
      final ok = await widget.notifier.retryTextMessage(
        conversationId: m.conversationId,
        outboxId: outboxId,
      );
      if (!ok) {
        messenger.showSnackBar(
          const SnackBar(content: Text('Couldn’t resend — try again.')),
        );
      }
      return;
    }
    final ok = await widget.notifier.retryUpload(
      conversationId: m.conversationId,
      outboxId: outboxId,
    );
    if (!ok) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Media no longer cached — re-pick to re-send.'),
        ),
      );
    }
  }

  /// Saves a received image/video to the device photo gallery. Decrypts via
  /// the media pipeline (same path as the in-app viewer), then hands the bytes
  /// to `gal` (videos must go via a temp file — gal's video API takes a path).
  Future<void> _saveToGallery(BuildContext context, ChatMessage m) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      if (!await Gal.requestAccess()) {
        messenger.showSnackBar(
          const SnackBar(content: Text('Gallery permission denied.')),
        );
        return;
      }
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Saving…'),
          duration: Duration(seconds: 30),
        ),
      );
      final bytes = await widget.notifier.mediaBytesFor(m);
      if (bytes == null) {
        messenger.hideCurrentSnackBar();
        messenger.showSnackBar(
          const SnackBar(content: Text('Couldn’t load media to save.')),
        );
        return;
      }
      if (m.kind == MessageKind.image) {
        await Gal.putImageBytes(
          Uint8List.fromList(bytes),
          name: m.mediaFilename ?? 'image-${m.envelopeId}',
        );
      } else {
        // Sanitize the sender-supplied filename (blocks path traversal) and
        // write under the sweepable TempMediaStore prefix, then delete the
        // decrypted copy once Gal has ingested it — the gallery keeps its own
        // copy, so this temp file must not linger as plaintext.
        final path = await TempMediaStoreImpl().allocate(
          envelopeId: m.envelopeId,
          label: MediaFileOpener.sanitizeFilename(
            m.mediaFilename ?? 'video-${m.envelopeId}.mp4',
          ),
        );
        final file = File(path);
        try {
          await file.writeAsBytes(bytes, flush: true);
          await Gal.putVideo(path);
        } finally {
          try {
            await file.delete();
          } catch (_) {/* best-effort; sweepAll reclaims a straggler */}
        }
      }
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(const SnackBar(content: Text('Saved to gallery')));
    } on GalException catch (e) {
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        SnackBar(content: Text('Save failed: ${e.type.message}')),
      );
    } catch (e) {
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(SnackBar(content: Text('Save failed: $e')));
    }
  }

  Future<void> _downloadFile(BuildContext context, ChatMessage m) async {
    final messenger = ScaffoldMessenger.of(context);
    final opener = MediaFileOpener(opener: OpenFilexFileOpener());
    try {
      final bytes = await widget.notifier.mediaBytesFor(m);
      if (bytes == null) {
        messenger.showSnackBar(
          const SnackBar(content: Text('Download failed.')),
        );
        return;
      }
      final result = await opener.writeAndOpen(
        envelopeId: m.envelopeId,
        filename: m.mediaFilename ?? 'attachment',
        bytes: bytes,
      );
      if (result.success) return;
      messenger.showSnackBar(
        SnackBar(content: Text(_openErrorMessage(result, m.mediaFilename))),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Download failed: $e')));
    }
  }

  static String _openErrorMessage(FileOpenResult r, String? filename) {
    switch (r.status) {
      case FileOpenStatus.noAppToOpen:
        return 'No app installed to open ${filename ?? "this file"}.';
      case FileOpenStatus.permissionDenied:
        return 'Permission denied opening ${filename ?? "this file"}.';
      case FileOpenStatus.fileNotFound:
        return 'Saved file could not be located.';
      case FileOpenStatus.error:
        return r.message ?? 'Could not open file.';
      case FileOpenStatus.ok:
        return '';
    }
  }
}
