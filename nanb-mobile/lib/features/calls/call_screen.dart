import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../../app/design_tokens.dart';
import '../../app/providers.dart';
import '../../app/theme.dart';
import '../chat/widgets/nanb_avatar.dart';
import 'call_controller.dart';
import 'models/call_session.dart';
import 'models/call_signal.dart';
import 'webrtc_call_media_engine.dart';

/// Full-screen 1:1 call UI, driven entirely by [CallController] state. Rendered
/// by [CallOverlay] above all app content whenever a call session is live.
///
/// Audio calls show the classic avatar + status + controls. Video calls show
/// the remote feed full-screen with a mirrored local preview picture-in-picture
/// and add camera on/off + flip-camera controls. The video surfaces bind to the
/// live engine's renderers (read via [CallController.engine]) — the only place
/// the WebRTC media stack reaches the UI.
class CallScreen extends ConsumerStatefulWidget {
  const CallScreen({super.key, required this.session, this.onMinimize});

  final CallSession session;

  /// Collapses the call to the top banner so the app underneath is usable.
  /// Null hides the button (e.g. while an inbound call is still ringing).
  final VoidCallback? onMinimize;

  @override
  ConsumerState<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends ConsumerState<CallScreen> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    // Re-render once a second so the in-call duration updates (and so the
    // remote video surface swaps in shortly after the peer's track arrives).
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  String _statusLine(CallSession s) {
    switch (s.status) {
      case CallStatus.incomingRinging:
        return s.mediaKind == CallMediaKind.video
            ? 'Incoming video call'
            : 'Incoming call';
      case CallStatus.outgoingRinging:
        return 'Calling…';
      case CallStatus.connecting:
        return 'Connecting…';
      case CallStatus.active:
        return _formatDuration(s.connectedAt);
      case CallStatus.ended:
        return 'Call ended';
    }
  }

  String _formatDuration(DateTime? connectedAt) {
    if (connectedAt == null) return '0:00';
    final secs = DateTime.now().toUtc().difference(connectedAt).inSeconds;
    final m = (secs ~/ 60).toString();
    final s = (secs % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final t = DesignTokens.of(context);
    // Watch (not read) so the screen rebuilds when the engine + its renderers
    // become available and when camera state toggles.
    final controller = ref.watch(callControllerProvider);
    final s = widget.session;
    final body = s.mediaKind == CallMediaKind.video
        ? _buildVideo(t, controller, s)
        : _buildAudio(t, controller, s);
    final minimize = widget.onMinimize;
    if (minimize == null || !_canMinimize(s.status)) return body;
    return Stack(
      fit: StackFit.expand,
      children: [
        body,
        Positioned(
          top: 0,
          left: 0,
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: IconButton(
                key: const ValueKey('call-minimize'),
                tooltip: 'Minimize call',
                icon: Icon(
                  Icons.keyboard_arrow_down,
                  size: 32,
                  color: s.mediaKind == CallMediaKind.video
                      ? Colors.white
                      : t.text,
                ),
                onPressed: minimize,
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// A ringing inbound call must be answered/declined on the full screen; every
  /// other live state can be minimized.
  static bool _canMinimize(CallStatus status) =>
      status == CallStatus.outgoingRinging ||
      status == CallStatus.connecting ||
      status == CallStatus.active;

  // ── Audio call (avatar layout) ─────────────────────────────────────────────

  Widget _buildAudio(DesignTokens t, CallController controller, CallSession s) {
    final name = s.peerUsername.isEmpty ? 'Unknown' : s.peerUsername;
    return Material(
      color: t.bg,
      child: SafeArea(
        child: Column(
          children: [
            const Spacer(flex: 2),
            NanbAvatar(name: name, size: 96),
            const SizedBox(height: 20),
            Text(name, style: monoStyle(fontSize: 20, color: t.text)),
            const SizedBox(height: 8),
            Text(
              _statusLine(s),
              style: monoStyle(
                fontSize: 13,
                color: t.textMuted,
                letterSpacing: 0.5,
              ),
            ),
            const Spacer(flex: 3),
            _Controls(t: t, session: s, controller: controller),
            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }

  // ── Video call (remote full-screen + local PiP) ────────────────────────────

  Widget _buildVideo(DesignTokens t, CallController controller, CallSession s) {
    final name = s.peerUsername.isEmpty ? 'Unknown' : s.peerUsername;
    final engine = controller.engine;
    final webrtc = engine is WebrtcCallMediaEngine ? engine : null;
    final remote = webrtc?.remoteVideoRenderer;
    final local = webrtc?.localVideoRenderer;
    final remoteActive = s.status == CallStatus.active &&
        remote != null &&
        remote.srcObject != null;

    return Material(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Remote feed once it arrives; until then a dark avatar placeholder.
          if (remoteActive)
            RTCVideoView(
              remote,
              objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
            )
          else
            Container(
              color: const Color(0xFF111317),
              alignment: Alignment.center,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  NanbAvatar(name: name, size: 88),
                  const SizedBox(height: 18),
                  Text(name,
                      style: monoStyle(fontSize: 18, color: Colors.white)),
                ],
              ),
            ),

          // Local preview (top-right). Shown once the camera is up; a dark tile
          // with a crossed-camera glyph when the user turned their video off.
          if (local != null)
            Positioned(
              top: 0,
              right: 0,
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: SizedBox(
                      width: 104,
                      height: 150,
                      child: s.cameraEnabled
                          ? RTCVideoView(
                              local,
                              mirror: s.usingFrontCamera,
                              objectFit: RTCVideoViewObjectFit
                                  .RTCVideoViewObjectFitCover,
                            )
                          : Container(
                              color: const Color(0xFF22262C),
                              alignment: Alignment.center,
                              child: const Icon(Icons.videocam_off,
                                  color: Colors.white54, size: 26),
                            ),
                    ),
                  ),
                ),
              ),
            ),

          // Name + status, top-left over a readability scrim.
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: _TopScrim(name: name, status: _statusLine(s)),
          ),

          // Controls, bottom over a scrim.
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Container(
              padding: const EdgeInsets.only(top: 24),
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [Colors.black87, Colors.transparent],
                ),
              ),
              // Keep the controls + their labels clear of the system nav bar —
              // the video layout is a full-screen Stack (no outer SafeArea), so
              // without this the bottom labels (End / Mute / …) get clipped by
              // the gesture/button bar. `minimum` keeps the old 36px gap on
              // devices with no bottom inset (gesture nav).
              child: SafeArea(
                top: false,
                minimum: const EdgeInsets.only(bottom: 36),
                child: _Controls(
                  t: t,
                  session: s,
                  controller: controller,
                  onDark: true,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TopScrim extends StatelessWidget {
  const _TopScrim({required this.name, required this.status});
  final String name;
  final String status;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.only(top: 12, bottom: 28, left: 64, right: 20),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.black54, Colors.transparent],
        ),
      ),
      child: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(name,
                style: monoStyle(fontSize: 18, color: Colors.white)),
            const SizedBox(height: 4),
            Text(
              status,
              style: monoStyle(
                fontSize: 12,
                color: Colors.white70,
                letterSpacing: 0.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Controls extends StatelessWidget {
  const _Controls({
    required this.t,
    required this.session,
    required this.controller,
    this.onDark = false,
  });
  final DesignTokens t;
  final CallSession session;
  final CallController controller;

  /// True when laid over a dark video feed — idle buttons use a translucent
  /// white tile + white glyph instead of the surface tokens.
  final bool onDark;

  Color get _idleColor => onDark ? Colors.white24 : t.surfaceAlt;
  Color get _idleIcon => onDark ? Colors.white : t.text;

  @override
  Widget build(BuildContext context) {
    final isVideo = session.mediaKind == CallMediaKind.video;
    switch (session.status) {
      case CallStatus.incomingRinging:
        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _RoundButton(
              key: const ValueKey('call-decline'),
              icon: Icons.call_end,
              color: t.danger,
              label: 'Decline',
              onTap: controller.decline,
            ),
            _RoundButton(
              key: const ValueKey('call-accept'),
              icon: isVideo ? Icons.videocam : Icons.call,
              color: const Color(0xFF2E9E5B),
              label: 'Accept',
              onTap: controller.accept,
            ),
          ],
        );
      case CallStatus.outgoingRinging:
      case CallStatus.connecting:
        return Center(
          child: _RoundButton(
            key: const ValueKey('call-end'),
            icon: Icons.call_end,
            color: t.danger,
            label: 'End',
            onTap: controller.hangup,
          ),
        );
      case CallStatus.active:
        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _RoundButton(
              key: const ValueKey('call-mute'),
              icon: session.micMuted ? Icons.mic_off : Icons.mic,
              color: session.micMuted ? t.accent : _idleColor,
              iconColor: session.micMuted ? t.accentOn : _idleIcon,
              label: session.micMuted ? 'Unmute' : 'Mute',
              onTap: () => controller.setMicMuted(!session.micMuted),
            ),
            if (isVideo) ...[
              _RoundButton(
                key: const ValueKey('call-camera'),
                icon:
                    session.cameraEnabled ? Icons.videocam : Icons.videocam_off,
                color: session.cameraEnabled ? _idleColor : t.accent,
                iconColor: session.cameraEnabled ? _idleIcon : t.accentOn,
                label: session.cameraEnabled ? 'Camera' : 'Camera off',
                onTap: () =>
                    controller.setCameraEnabled(!session.cameraEnabled),
              ),
              _RoundButton(
                key: const ValueKey('call-flip'),
                icon: Icons.flip_camera_ios,
                color: _idleColor,
                iconColor: _idleIcon,
                label: 'Flip',
                onTap: session.cameraEnabled ? controller.switchCamera : null,
              ),
            ],
            _RoundButton(
              key: const ValueKey('call-end'),
              icon: Icons.call_end,
              color: t.danger,
              label: 'End',
              onTap: controller.hangup,
            ),
            _RoundButton(
              key: const ValueKey('call-speaker'),
              icon: session.speakerOn ? Icons.volume_up : Icons.volume_down,
              color: session.speakerOn ? t.accent : _idleColor,
              iconColor: session.speakerOn ? t.accentOn : _idleIcon,
              label: 'Speaker',
              onTap: () => controller.setSpeakerOn(!session.speakerOn),
            ),
          ],
        );
      case CallStatus.ended:
        return const SizedBox(height: 64);
    }
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({
    super.key,
    required this.icon,
    required this.color,
    required this.label,
    required this.onTap,
    this.iconColor = Colors.white,
  });
  final IconData icon;
  final Color color;
  final Color iconColor;
  final String label;

  /// Null disables the button (dimmed) — e.g. flip while the camera is off.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = DesignTokens.of(context);
    final disabled = onTap == null;
    return Opacity(
      opacity: disabled ? 0.4 : 1,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Material(
            color: color,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Icon(icon, color: iconColor, size: 24),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(label, style: monoStyle(fontSize: 11, color: t.textMuted)),
        ],
      ),
    );
  }
}
