import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../app/design_tokens.dart';
import '../conversations_notifier.dart';
import '../models/chat_message.dart';
import '../models/message_kind.dart';

/// One square in the shared-media grid: the decrypted photo, or a video's first
/// frame with a play badge. Bytes load lazily so a long grid decrypts only what
/// scrolls into view.
class SharedMediaTile extends StatefulWidget {
  const SharedMediaTile({
    super.key,
    required this.message,
    required this.notifier,
    required this.onTap,
  });

  final ChatMessage message;
  final ConversationsNotifier notifier;
  final void Function(Uint8List? bytes) onTap;

  @override
  State<SharedMediaTile> createState() => _SharedMediaTileState();
}

class _SharedMediaTileState extends State<SharedMediaTile> {
  Uint8List? _bytes;

  bool get _isVideo => widget.message.kind == MessageKind.video;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final Uint8List? bytes;
      if (_isVideo) {
        bytes = await widget.notifier.videoThumbnailFor(widget.message);
      } else {
        final raw = await widget.notifier.mediaBytesFor(widget.message);
        bytes = raw == null ? null : Uint8List.fromList(raw);
      }
      if (mounted) setState(() => _bytes = bytes);
    } catch (_) {
      // Undecryptable / expired media stays a placeholder tile.
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = DesignTokens.of(context);
    final bytes = _bytes;
    return GestureDetector(
      onTap: () => widget.onTap(bytes),
      child: Container(
        color: t.surfaceAlt,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (bytes != null)
              Image.memory(
                bytes,
                fit: BoxFit.cover,
                cacheWidth: 360,
                gaplessPlayback: true,
                errorBuilder: (_, _, _) => const SizedBox.shrink(),
              ),
            if (_isVideo)
              const Center(
                child: Icon(Icons.play_circle_fill,
                    size: 32, color: Colors.white70),
              ),
          ],
        ),
      ),
    );
  }
}
