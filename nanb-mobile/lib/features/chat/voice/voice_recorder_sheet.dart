import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/design_tokens.dart';
import '../../../app/theme.dart';
import 'voice_recorder_controller.dart';

/// Bottom-sheet UI for recording a voice note. Auto-starts recording on
/// open. Send → returns the file path + waveform; Cancel → returns null. The
/// chat thread reads the file bytes + calls `sendVoice`.
class VoiceRecorderSheet extends ConsumerStatefulWidget {
  const VoiceRecorderSheet({super.key});

  /// Pushes the sheet and returns the recorded `.m4a` path + waveform, or
  /// null when the user cancelled or permission was denied.
  static Future<VoiceRecordingResult?> show(BuildContext context) {
    return showModalBottomSheet<VoiceRecordingResult?>(
      context: context,
      isDismissible: false,
      enableDrag: false,
      backgroundColor: Colors.transparent,
      builder: (_) => const VoiceRecorderSheet(),
    );
  }

  @override
  ConsumerState<VoiceRecorderSheet> createState() => _VoiceRecorderSheetState();
}

class _VoiceRecorderSheetState extends ConsumerState<VoiceRecorderSheet> {
  late final VoiceRecorderController _controller;
  Duration _elapsed = Duration.zero;
  StreamSubscription<Duration>? _sub;
  String? _error;

  /// False until `startRecorder` actually resolves — on a real device the
  /// mic takes ~0.5-1.5s to go live, and showing "Recording…" during that
  /// window invites the user to start talking into a dead mic (their first
  /// words were silently lost). Send stays disabled until this flips.
  bool _live = false;

  /// True while stop() runs (tail grace + encoder finalization).
  bool _finishing = false;

  @override
  void initState() {
    super.initState();
    // tailGrace: keep capturing for a beat after Send — users tap while
    // finishing their last word, and 300ms proved too short for real
    // speech cadence.
    _controller = VoiceRecorderController(
      tailGrace: const Duration(milliseconds: 1000),
    );
    _start();
  }

  Future<void> _start() async {
    try {
      await _controller.start();
      _sub = _controller.elapsed.listen((e) {
        if (mounted) setState(() => _elapsed = e);
      });
      if (mounted) setState(() => _live = true);
    } catch (e) {
      // StateError carries a human-readable message (e.g. permission
      // denied) — show it without the "Bad state:" prefix toString adds.
      final msg = e is StateError ? e.message.toString() : e.toString();
      if (mounted) setState(() => _error = msg);
    }
  }

  Future<void> _send() async {
    if (_finishing) return;
    setState(() => _finishing = true);
    final result = await _controller.stop();
    if (!mounted) return;
    Navigator.of(context).pop(result);
  }

  Future<void> _cancel() async {
    await _controller.cancel();
    if (!mounted) return;
    Navigator.of(context).pop(null);
  }

  @override
  void dispose() {
    _sub?.cancel();
    _controller.dispose();
    super.dispose();
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.toString();
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final t = DesignTokens.of(context);
    return SafeArea(
      child: Container(
        margin: const EdgeInsets.all(12),
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: t.surface,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_error != null) ...[
              Text(_error!, style: TextStyle(color: t.danger)),
              const SizedBox(height: 12),
              TextButton(
                onPressed: _cancel,
                child: const Text('Close'),
              ),
            ] else ...[
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: t.danger,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _fmt(_elapsed),
                    style: monoStyle(fontSize: 22, color: t.text),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Text(
                _finishing
                    ? 'Finishing…'
                    : _live
                        ? 'Recording…'
                        : 'Starting…',
                style: TextStyle(color: t.textMuted, fontSize: 13),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  TextButton(
                    onPressed: _finishing ? null : _cancel,
                    child: const Text('Cancel'),
                  ),
                  ElevatedButton(
                    // Disabled until the mic is live: talking before that
                    // records nothing, so a too-early Send would ship a
                    // clip missing its first words.
                    onPressed: _live && !_finishing ? _send : null,
                    child: const Text('Send'),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
