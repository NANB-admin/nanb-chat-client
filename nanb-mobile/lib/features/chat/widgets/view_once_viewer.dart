import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../../core/platform/secure_screen.dart';
import '../models/message_kind.dart';
import '../models/view_once_content.dart';
import '../services/temp_media_store.dart';
import '../voice/voice_player_controller.dart';

/// Shows a view-once message the one time it can be seen. Screenshots and
/// screen recording are blocked while it's open, and whatever it wrote to disk
/// (a video has to be a file to play) is deleted on close.
class ViewOnceViewer extends StatefulWidget {
  const ViewOnceViewer({super.key, required this.content});

  final ViewOnceContent content;

  static Future<void> open(BuildContext context, ViewOnceContent content) {
    return Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => ViewOnceViewer(content: content),
      ),
    );
  }

  @override
  State<ViewOnceViewer> createState() => _ViewOnceViewerState();
}

class _ViewOnceViewerState extends State<ViewOnceViewer> {
  /// Temp files for this viewer are named after this, so all of them go on close.
  late final String _tempId =
      'viewonce-${DateTime.now().toUtc().microsecondsSinceEpoch}';
  final _tempStore = TempMediaStoreImpl();
  VideoPlayerController? _video;
  VoicePlayerController? _voice;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(SecureScreen.pushProtected());
    final bytes = widget.content.bytes;
    if (bytes == null) return;
    switch (widget.content.kind) {
      case MessageKind.video:
        _loadVideo(bytes);
      case MessageKind.voice:
        _loadVoice(bytes);
      default:
        break;
    }
  }

  Future<void> _loadVideo(List<int> bytes) async {
    try {
      final path =
          await _tempStore.allocate(envelopeId: _tempId, label: 'video.mp4');
      await File(path).writeAsBytes(bytes, flush: true);
      final c = VideoPlayerController.file(File(path));
      await c.initialize();
      if (!mounted) {
        await c.dispose();
        return;
      }
      setState(() => _video = c);
      await c.play();
    } catch (_) {
      if (mounted) setState(() => _error = "Couldn't play this video.");
    }
  }

  Future<void> _loadVoice(List<int> bytes) async {
    try {
      final c = VoicePlayerController();
      await c.load(bytes);
      if (!mounted) {
        await c.dispose();
        return;
      }
      setState(() => _voice = c);
      await c.toggle();
    } catch (_) {
      if (mounted) setState(() => _error = "Couldn't play this voice message.");
    }
  }

  @override
  void dispose() {
    _video?.dispose();
    _voice?.dispose();
    unawaited(_tempStore.deleteForEnvelope(_tempId));
    unawaited(SecureScreen.popProtected());
    super.dispose();
  }

  Widget _body() {
    final c = widget.content;
    if (_error != null) return _centredText(_error!);
    switch (c.kind) {
      case MessageKind.image:
        return InteractiveViewer(
          minScale: 1,
          maxScale: 6,
          child: Center(child: Image.memory(Uint8List.fromList(c.bytes!))),
        );
      case MessageKind.video:
        final v = _video;
        if (v == null) return const Center(child: CircularProgressIndicator());
        return Center(
          child: AspectRatio(aspectRatio: v.value.aspectRatio, child: VideoPlayer(v)),
        );
      case MessageKind.voice:
        final p = _voice;
        if (p == null) return const Center(child: CircularProgressIndicator());
        return ListenableBuilder(
          listenable: p,
          builder: (_, _) => Center(
            child: IconButton(
              iconSize: 64,
              color: Colors.white,
              tooltip: p.isPlaying ? 'Pause' : 'Play',
              icon: Icon(p.isPlaying ? Icons.pause_circle : Icons.play_circle),
              onPressed: p.toggle,
            ),
          ),
        );
      default:
        return _centredText(c.text);
    }
  }

  Widget _centredText(String text) => Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Text(text,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white, fontSize: 20)),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final caption = widget.content.kind == MessageKind.text
        ? ''
        : widget.content.text;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          Positioned.fill(child: _body()),
          if (caption.isNotEmpty)
            Positioned(
              left: 16,
              right: 16,
              bottom: 32,
              child: Text(caption,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white, fontSize: 15)),
            ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Row(
                children: [
                  IconButton(
                    tooltip: 'Close',
                    icon: const Icon(Icons.close, color: Colors.white),
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                  const SizedBox(width: 8),
                  const Text('View once',
                      style: TextStyle(color: Colors.white70, fontSize: 14)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
