import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router.dart';
import '../conversations_notifier.dart';
import '../models/chat_message.dart';
import '../voice/voice_player_controller.dart';
import 'message_bubble.dart';
import 'image_viewer_screen.dart';
import 'message_bubble_image.dart';
import 'message_bubble_video.dart';
import 'message_bubble_voice.dart';

/// Media-message bubble hosts used by the chat thread's message list. Each
/// lazily fetches its decrypted bytes/thumbnail from the notifier and renders
/// the matching presentational bubble. Extracted from `chat_thread_screen.dart`.

/// Overlays the upload spinner / retry chip and the delivery tick on a media
/// bubble (image/video) without covering the timestamp painted on the media.
class MediaBubbleStatusWrap extends StatelessWidget {
  const MediaBubbleStatusWrap({
    super.key,
    required this.child,
    required this.uploading,
    required this.failed,
    required this.status,
    required this.readColor,
    required this.faintColor,
    this.onRetry,
  });

  final Widget child;
  final bool uploading;
  final bool failed;
  final BubbleStatus? status;
  final Color readColor;
  final Color faintColor;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    Widget content = child;
    if (failed) {
      // Tap retries; long-press is reserved for the message-actions menu
      // (delete / retry) wired one level up in the message list.
      content = InkWell(
        onTap: onRetry,
        borderRadius: BorderRadius.circular(14),
        child: child,
      );
    }
    // Transient upload spinner / retry chip stay overlaid on the media corner.
    final media = (uploading || failed)
        ? Stack(
            clipBehavior: Clip.none,
            children: [
              content,
              Positioned(right: 6, bottom: 6, child: _statusBadge()),
            ],
          )
        : content;
    // The persistent delivery tick sits BELOW the attachment, right-aligned, so
    // it never covers the timestamp painted on the media itself.
    final icon = _tickIcon();
    if (icon == null) return media;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        media,
        Padding(
          padding: const EdgeInsets.only(top: 3, right: 2),
          child: Icon(
            icon,
            size: 13,
            color: status == BubbleStatus.read ? readColor : faintColor,
          ),
        ),
      ],
    );
  }

  Widget _statusBadge() {
    if (failed) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.red.shade700,
          borderRadius: BorderRadius.circular(10),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 12, color: Colors.white),
            SizedBox(width: 4),
            Text(
              'Tap to retry',
              style: TextStyle(
                color: Colors.white,
                fontSize: 10,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      );
    }
    if (uploading) {
      return Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(10),
        ),
        child: const SizedBox(
          width: 12,
          height: 12,
          child: CircularProgressIndicator(
            strokeWidth: 1.5,
            valueColor: AlwaysStoppedAnimation(Colors.white),
          ),
        ),
      );
    }
    return const SizedBox.shrink();
  }

  IconData? _tickIcon() {
    switch (status) {
      case BubbleStatus.sent:
        return Icons.check;
      case BubbleStatus.delivered:
      case BubbleStatus.read:
        return Icons.done_all;
      case BubbleStatus.pending:
      case null:
        return null;
    }
  }
}

/// Async-load wrapper around `MessageBubbleImage`. Lazy-fetches the
/// decrypted bytes via `notifier.mediaBytesFor`; the bubble shows a
/// stripe placeholder until they arrive.
class ImageBubbleAsync extends StatefulWidget {
  const ImageBubbleAsync({super.key, required this.message, required this.notifier});
  final ChatMessage message;
  final ConversationsNotifier notifier;

  @override
  State<ImageBubbleAsync> createState() => _ImageBubbleAsyncState();
}

class _ImageBubbleAsyncState extends State<ImageBubbleAsync> {
  // Held in State (not a Future) so a status-tick rebuild — OR the State being
  // recreated at the optimistic→acked envelope-id swap, which re-keys the row —
  // never drops back to the placeholder: a synchronous cache peek in initState
  // paints the already-decrypted bytes on the very first frame.
  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    final cached = widget.notifier.cachedMediaBytes(widget.message);
    if (cached != null) {
      // Reuse the cached instance verbatim (no copy). The SAME Uint8List is
      // held under both the outbox-id and server-id cache keys, so across the
      // ack-time bubble recreation Image.memory keys to the SAME MemoryImage
      // and Flutter's global image cache hits — zero re-decode, no flicker.
      _bytes = cached is Uint8List ? cached : Uint8List.fromList(cached);
    } else {
      _load();
    }
  }

  @override
  void didUpdateWidget(ImageBubbleAsync old) {
    super.didUpdateWidget(old);
    // A message's media is immutable, so once we hold bytes we keep them across
    // rebuilds. Only (re)load when there's still nothing to show.
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

  String? get _sizeLabel {
    final s = widget.message.mediaSize;
    if (s == null) return null;
    if (s < 1024) return '$s B';
    if (s < 1024 * 1024) return '${(s / 1024).toStringAsFixed(1)} KB';
    return '${(s / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    final caption = bytes == null && widget.message.body.isEmpty
        ? 'Decrypting…'
        : (widget.message.body.isEmpty ? null : widget.message.body);
    return MessageBubbleImage(
      time: _time,
      mine: widget.message.mine,
      caption: caption,
      size: _sizeLabel,
      bytes: bytes,
      onTap: bytes == null
          ? null
          : () => ImageViewerScreen.open(context, bytes),
    );
  }
}

/// Voice-bubble host that owns a per-message `VoicePlayerController`.
/// Bytes are fetched + decrypted on the first play tap (lazy) so scrolling
/// past unread voice notes doesn't fan out a wave of downloads.
class VoiceBubble extends StatefulWidget {
  const VoiceBubble({super.key, required this.message, required this.notifier});

  final ChatMessage message;
  final ConversationsNotifier notifier;

  @override
  State<VoiceBubble> createState() => _VoiceBubbleState();
}

class _VoiceBubbleState extends State<VoiceBubble> {
  VoicePlayerController? _controller;
  bool _loading = false;

  /// Synchronous re-entry gate. `_loading` only flips inside a `setState`
  /// call, so a tight double-tap can clear the first `if (_controller == null)`
  /// guard twice before the async download finishes. This non-async flag
  /// short-circuits the second tap before any state mutation.
  bool _busy = false;

  Future<void> _togglePlay() async {
    if (_busy) return;
    _busy = true;
    try {
      if (_controller == null) {
        setState(() => _loading = true);
        try {
          final bytes = await widget.notifier.mediaBytesFor(widget.message);
          if (bytes == null) {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Could not load voice note.')),
              );
            }
            return;
          }
          final c = VoicePlayerController();
          await c.load(bytes);
          if (!mounted) {
            await c.dispose();
            return;
          }
          _controller = c;
        } finally {
          if (mounted) setState(() => _loading = false);
        }
      }
      await _controller?.toggle();
    } finally {
      _busy = false;
    }
  }

  String get _hhmm {
    final l = widget.message.serverTs.toLocal();
    final hh = l.hour.toString().padLeft(2, '0');
    final mm = l.minute.toString().padLeft(2, '0');
    return '$hh:$mm';
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  /// Pre-load duration label from the descriptor — shows the real length
  /// before the audio is downloaded (the controller takes over after load).
  String get _fallbackDuration {
    final ms = widget.message.mediaDurationMs;
    if (ms == null || ms <= 0) return '0:00';
    final d = Duration(milliseconds: ms);
    final m = d.inMinutes.toString();
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    return MessageBubbleVoice(
      time: _hhmm,
      mine: widget.message.mine,
      controller: c,
      duration: _fallbackDuration,
      onPlayPause: _loading ? null : _togglePlay,
      // Scrubbing needs a loaded track; before first play a seek tap is
      // treated as a play request so the gesture always does something.
      onSeek: c == null ? (_) => _togglePlay() : (f) => c.seekToFraction(f),
      waveformSamples: widget.message.voiceWaveform,
    );
  }
}

/// Video-bubble host that asks the notifier for a decoded first-frame JPEG.
/// The notifier owns the thumbnail cache: a bubble scrolled off-screen and
/// back gets a synchronous cache hit instead of re-running the native decode.
/// Until the first thumbnail arrives, the bubble shows the existing black
/// surface as a fallback.
class VideoBubbleAsync extends StatefulWidget {
  const VideoBubbleAsync({super.key, required this.message, required this.notifier});

  final ChatMessage message;
  final ConversationsNotifier notifier;

  @override
  State<VideoBubbleAsync> createState() => _VideoBubbleAsyncState();
}

class _VideoBubbleAsyncState extends State<VideoBubbleAsync> {
  Uint8List? _thumbnail;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final thumb = await widget.notifier.videoThumbnailFor(widget.message);
    if (!mounted || thumb == null) return;
    setState(() => _thumbnail = thumb);
  }

  String get _hhmm {
    final l = widget.message.serverTs.toLocal();
    final hh = l.hour.toString().padLeft(2, '0');
    final mm = l.minute.toString().padLeft(2, '0');
    return '$hh:$mm';
  }

  String get _sizeLabel {
    final s = widget.message.mediaSize ?? 0;
    if (s < 1024) return '$s B';
    if (s < 1024 * 1024) return '${(s / 1024).toStringAsFixed(1)} KB';
    if (s < 1024 * 1024 * 1024) {
      return '${(s / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(s / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }

  @override
  Widget build(BuildContext context) {
    return MessageBubbleVideo(
      size: _sizeLabel,
      time: _hhmm,
      mine: widget.message.mine,
      caption: widget.message.body,
      thumbnail: _thumbnail,
      onTap: () => context.push(
        Routes.videoPlayer
            .replaceFirst(':conversationId', widget.message.conversationId)
            .replaceFirst(':envelopeId', widget.message.envelopeId),
      ),
    );
  }
}
