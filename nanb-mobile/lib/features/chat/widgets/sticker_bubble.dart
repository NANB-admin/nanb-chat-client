import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../app/design_tokens.dart';
import '../../../app/theme.dart';
import '../conversations_notifier.dart';
import '../models/chat_message.dart';

/// A sticker in the thread: just the image on the chat background — no bubble
/// fill, border, caption or size/cipher badge — with the time underneath.
///
/// Lazy-loads the decrypted bytes exactly like `ImageBubbleAsync` (a synchronous
/// cache peek first, so a status-tick rebuild never flashes the placeholder).
class StickerBubbleAsync extends StatefulWidget {
  const StickerBubbleAsync({
    super.key,
    required this.message,
    required this.notifier,
  });

  final ChatMessage message;
  final ConversationsNotifier notifier;

  @override
  State<StickerBubbleAsync> createState() => _StickerBubbleAsyncState();
}

class _StickerBubbleAsyncState extends State<StickerBubbleAsync> {
  static const _edge = 150.0;

  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    final cached = widget.notifier.cachedMediaBytes(widget.message);
    if (cached != null) {
      _bytes = cached is Uint8List ? cached : Uint8List.fromList(cached);
    } else {
      _load();
    }
  }

  @override
  void didUpdateWidget(StickerBubbleAsync old) {
    super.didUpdateWidget(old);
    if (_bytes == null) _load();
  }

  Future<void> _load() async {
    final bytes = await widget.notifier.mediaBytesFor(widget.message);
    if (!mounted || bytes == null) return;
    setState(
        () => _bytes = bytes is Uint8List ? bytes : Uint8List.fromList(bytes));
  }

  String get _time {
    final l = widget.message.serverTs.toLocal();
    final hh = l.hour.toString().padLeft(2, '0');
    final mm = l.minute.toString().padLeft(2, '0');
    return '$hh:$mm';
  }

  @override
  Widget build(BuildContext context) {
    final t = DesignTokens.of(context);
    final mine = widget.message.mine;
    final bytes = _bytes;
    final dpr = MediaQuery.of(context).devicePixelRatio;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 2),
        child: Column(
          crossAxisAlignment:
              mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: _edge,
              height: _edge,
              child: bytes == null
                  ? DecoratedBox(
                      decoration: BoxDecoration(
                        color: t.surfaceAlt,
                        borderRadius: BorderRadius.circular(16),
                      ),
                    )
                  : Image.memory(
                      bytes,
                      fit: BoxFit.contain,
                      cacheWidth: (_edge * dpr).round(),
                      gaplessPlayback: true,
                    ),
            ),
            Text(
              _time,
              style: monoStyle(
                fontSize: 9.5,
                color: t.textFaint,
                letterSpacing: 0.3,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
