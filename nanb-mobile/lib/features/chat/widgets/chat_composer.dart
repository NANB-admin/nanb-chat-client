import 'package:flutter/material.dart';

import '../../../app/design_tokens.dart';

/// Translated from the design's `Composer`. Attach + text + emoji + send pill.
/// The send pill flips to a mic when the text field is empty AND `onMic` is
/// provided.
class ChatComposer extends StatefulWidget {
  const ChatComposer({
    super.key,
    required this.controller,
    required this.onSend,
    this.onAttach,
    this.onMic,
    this.onEmoji,
    this.emojiOpen = false,
    this.focusNode,
    this.placeholder = 'Type a message…',
  });

  final TextEditingController controller;
  final VoidCallback onSend;

  /// Tapped when the user wants to attach a photo / video / file. When null
  /// the attach button is disabled — used during in-flight uploads.
  final VoidCallback? onAttach;

  /// Tapped when the user wants to record a voice note. When non-null and
  /// the text field is empty, the send pill renders as a mic icon.
  final VoidCallback? onMic;

  /// Toggles the inline emoji panel (owned by the host so the text field stays
  /// visible above it). Null disables the emoji button.
  final VoidCallback? onEmoji;

  /// Whether the emoji panel is currently open — flips the emoji button to a
  /// keyboard icon so tapping it again returns to the keyboard.
  final bool emojiOpen;

  /// Focus node for the text field, owned by the host so it can hide the emoji
  /// panel when the keyboard is summoned.
  final FocusNode? focusNode;

  final String placeholder;

  @override
  State<ChatComposer> createState() => _ChatComposerState();
}

class _ChatComposerState extends State<ChatComposer> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onChanged);
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = DesignTokens.of(context);
    final hasText = widget.controller.text.trim().isNotEmpty;
    final showSend = hasText || widget.onMic == null;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: t.surface,
        border: Border(top: BorderSide(color: t.border)),
      ),
      child: Row(
        // Keep attach + send anchored to the bottom as the field grows taller.
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          IconButton(
            icon: Icon(Icons.attach_file, color: t.textMuted),
            iconSize: 20,
            padding: const EdgeInsets.all(6),
            constraints: const BoxConstraints(),
            onPressed: widget.onAttach,
          ),
          Expanded(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                color: t.surfaceAlt,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: t.border),
              ),
              child: Row(
                // Emoji button sits beside the last line as the field grows.
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: TextField(
                      controller: widget.controller,
                      focusNode: widget.focusNode,
                      // Multiline: the keyboard shows a return/newline key
                      // (instead of a "Done" checkmark) and the field grows with
                      // the text up to [maxLines] before scrolling internally.
                      // Sending stays on the send button, so Enter inserts a
                      // newline rather than submitting.
                      keyboardType: TextInputType.multiline,
                      textInputAction: TextInputAction.newline,
                      textCapitalization: TextCapitalization.sentences,
                      minLines: 1,
                      maxLines: 6,
                      style: TextStyle(fontSize: 14, color: t.text),
                      decoration: InputDecoration(
                        hintText: widget.placeholder,
                        hintStyle: TextStyle(color: t.textFaint),
                        border: InputBorder.none,
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(vertical: 8),
                      ),
                    ),
                  ),
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: widget.onEmoji,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 2),
                      child: Icon(
                        widget.emojiOpen
                            ? Icons.keyboard_outlined
                            : Icons.emoji_emotions_outlined,
                        size: 18,
                        color: t.textMuted,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          // Send / mic. A Material circle + InkWell (not a bare GestureDetector)
          // so the tap is handled through Flutter's gesture arena with a ripple
          // confirming the press, and a comfortable 46px target — the old 36px
          // `deferToChild` pill made edge taps miss, so on slower devices (Nokia)
          // it took a few taps to send.
          Material(
            color: t.accent,
            shape: const CircleBorder(),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: showSend ? widget.onSend : widget.onMic,
              child: SizedBox(
                width: 46,
                height: 46,
                child: Center(
                  child: Icon(
                    showSend ? Icons.send : Icons.mic,
                    size: 20,
                    color: t.accentOn,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
