import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';

import '../../../app/providers.dart';
import '../models/chat_message.dart';
import '../services/temp_media_store.dart';

/// Fullscreen video player. Navigated to with conversationId + envelopeId;
/// pulls the message from `conversationsProvider`, decrypts bytes via
/// `mediaBytesFor`, writes them to a temp file (`video_player` has no
/// in-memory data source on mobile), then plays.
class VideoPlayerScreen extends ConsumerStatefulWidget {
  const VideoPlayerScreen({
    super.key,
    required this.conversationId,
    required this.envelopeId,
  });

  final String conversationId;
  final String envelopeId;

  @override
  ConsumerState<VideoPlayerScreen> createState() => _VideoPlayerScreenState();
}

class _VideoPlayerScreenState extends ConsumerState<VideoPlayerScreen> {
  VideoPlayerController? _controller;
  File? _tempFile;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final notifier = ref.read(conversationsProvider);
      final convo = notifier.byId(widget.conversationId);
      ChatMessage? msg;
      if (convo != null) {
        for (final m in convo.messages) {
          if (m.envelopeId == widget.envelopeId) {
            msg = m;
            break;
          }
        }
      }
      if (msg == null) {
        if (mounted) setState(() => _error = 'Message not found.');
        return;
      }
      final bytes = await notifier.mediaBytesFor(msg);
      if (bytes == null) {
        if (mounted) setState(() => _error = 'Could not load video.');
        return;
      }
      final path = await TempMediaStoreImpl().allocate(
        envelopeId: widget.envelopeId,
        label: 'video.mp4',
      );
      final f = File(path);
      await f.writeAsBytes(bytes, flush: true);
      _tempFile = f;
      final c = VideoPlayerController.file(f);
      try {
        await c.initialize();
        await c.play();
      } catch (_) {
        // Initialize/play failed — dispose the half-constructed controller
        // before it leaks into the outer catch block.
        await c.dispose();
        rethrow;
      }
      if (!mounted) {
        await c.dispose();
        return;
      }
      setState(() => _controller = c);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    // Best-effort cleanup; the OS evicts the temp dir eventually anyway.
    _tempFile?.delete().ignore();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
      ),
      body: Center(
        child: _error != null
            ? Text(_error!, style: const TextStyle(color: Colors.white))
            : _controller == null
                ? const CircularProgressIndicator()
                : AspectRatio(
                    aspectRatio: _controller!.value.aspectRatio,
                    child: VideoPlayer(_controller!),
                  ),
      ),
    );
  }
}
