import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/theme.dart';
import 'call_controller.dart';
import 'models/call_session.dart';
import 'models/call_signal.dart';

/// Slim "call in progress" bar shown at the top of the app while the full-screen
/// call UI is minimized, so the user can read and send messages mid-call. Tap
/// the bar to return to the call; the red button hangs up.
class CallBanner extends StatefulWidget {
  const CallBanner({
    super.key,
    required this.session,
    required this.controller,
    required this.onExpand,
  });

  /// Height of the bar's content, below the status bar inset.
  static const double contentHeight = 48;

  final CallSession session;
  final CallController controller;
  final VoidCallback onExpand;

  @override
  State<CallBanner> createState() => _CallBannerState();
}

class _CallBannerState extends State<CallBanner> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    // Re-render each second so the running duration advances.
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  String get _status {
    final s = widget.session;
    switch (s.status) {
      case CallStatus.active:
        final connectedAt = s.connectedAt;
        if (connectedAt == null) return '0:00';
        final secs = DateTime.now().toUtc().difference(connectedAt).inSeconds;
        return '${secs ~/ 60}:${(secs % 60).toString().padLeft(2, '0')}';
      case CallStatus.outgoingRinging:
        return 'Calling…';
      case CallStatus.connecting:
        return 'Connecting…';
      case CallStatus.ended:
        return 'Call ended';
      case CallStatus.incomingRinging:
        return 'Incoming call';
    }
  }

  @override
  Widget build(BuildContext context) {
    final name = widget.session.peerUsername.isEmpty
        ? 'Unknown'
        : widget.session.peerUsername;
    final isVideo = widget.session.mediaKind == CallMediaKind.video;
    return Material(
      key: const ValueKey('call-banner'),
      color: const Color(0xFF2E9E5B),
      child: SafeArea(
        bottom: false,
        child: InkWell(
          onTap: widget.onExpand,
          child: SizedBox(
            height: CallBanner.contentHeight,
            child: Padding(
              padding: const EdgeInsets.only(left: 16, right: 6),
              child: Row(
                children: [
                  Icon(isVideo ? Icons.videocam : Icons.call,
                      size: 18, color: Colors.white),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '$name · $_status',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: monoStyle(fontSize: 13, color: Colors.white),
                    ),
                  ),
                  Text('Tap to return',
                      style: monoStyle(fontSize: 10, color: Colors.white70)),
                  IconButton(
                    key: const ValueKey('call-banner-end'),
                    tooltip: 'End call',
                    icon: const Icon(Icons.call_end, color: Colors.white),
                    onPressed: widget.controller.hangup,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
