import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/platform/call_foreground_service.dart';
import '../../core/platform/call_window.dart';
import 'call_banner.dart';
import 'call_screen.dart';
import 'call_tones.dart';
import 'models/call_session.dart';

/// Wraps the app's content and overlays the full-screen [CallScreen] above it
/// whenever a call session is live — so an incoming call (or an active one)
/// appears over whatever the user was doing. An ended call lingers briefly
/// ("Call ended") then auto-dismisses.
class CallOverlay extends ConsumerStatefulWidget {
  const CallOverlay({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<CallOverlay> createState() => _CallOverlayState();
}

class _CallOverlayState extends ConsumerState<CallOverlay> {
  Timer? _dismissTimer;
  final CallTones _tones = CallTones();

  /// Id of the call the user minimized to the banner, or null when the full
  /// call screen is showing. Keyed by call id so a NEW call always opens full.
  String? _minimizedCallId;

  @override
  void initState() {
    super.initState();
    // Start the iOS CallKit bridge here because this widget wraps the whole
    // app: it is alive for as long as the UI is, which is what lets the bridge
    // REPLAY a ring (and an answer) that the native side buffered while no
    // Flutter engine existed — the "answered from the lock screen with the app
    // killed" path. A no-op off iOS.
    unawaited(ref.read(callKitBridgeProvider).start());
  }

  @override
  void dispose() {
    _dismissTimer?.cancel();
    unawaited(_tones.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<CallStatus?>(
      callControllerProvider.select((c) => c.current?.status),
      (prev, next) {
        // Ring tones: ringback while we wait for an answer; a ringtone for an
        // inbound call (when foregrounded); silence once connected/ended.
        switch (next) {
          case CallStatus.outgoingRinging:
            unawaited(_tones.startRingback());
          case CallStatus.incomingRinging:
            // Stay silent when the SYSTEM is already ringing this call: on iOS
            // the call arrived as a PushKit ring that CallKit is sounding, and
            // our tone on top of it is a second, out-of-phase ringtone. When
            // CallKit isn't involved (Android, or an iPhone whose VoIP token
            // hasn't registered yet and fell back to the in-band invite) this
            // is still the only ring there is.
            if (!ref.read(callKitBridgeProvider).systemIsRinging) {
              unawaited(_tones.startRingtone());
            }
          case CallStatus.connecting:
          case CallStatus.active:
          case CallStatus.ended:
          case null:
            unawaited(_tones.stop());
        }
        // Keep the screen on + over the keyguard for the whole live span of a
        // call (ring → connect → active), then let the device sleep/relock once
        // it ends. Without this the screen woke for the incoming ring but dozed
        // again after a few seconds (no wakelock on the call window).
        final live = next == CallStatus.incomingRinging ||
            next == CallStatus.outgoingRinging ||
            next == CallStatus.connecting ||
            next == CallStatus.active;
        final wasLive = prev == CallStatus.incomingRinging ||
            prev == CallStatus.outgoingRinging ||
            prev == CallStatus.connecting ||
            prev == CallStatus.active;
        unawaited(live ? CallWindow.engage() : CallWindow.release());
        // Keep the process alive in the background for the same live span, so an
        // audio call (or a minimized video call) survives a screen lock / app
        // switch — the screen wakelock above only helps while foreground. On
        // Android this runs a microphone foreground service; iOS uses the `audio`
        // background mode (this channel is a no-op there).
        unawaited(
            live ? CallForegroundService.start() : CallForegroundService.stop());
        // Retract the on-screen keyboard the moment a call appears over whatever
        // the user was doing. The soft keyboard is a native layer (iOS and
        // Android alike) that floats above the Flutter view, so a chat composer
        // that still holds focus keeps the keyboard up *over* this full-screen
        // call overlay — covering Accept/Decline while the composer that owns it
        // is hidden behind the call screen, so the user can neither answer the
        // call nor tap away to dismiss the keyboard. Dropping focus on the live
        // edge (not every status tick) closes that input connection and lets the
        // keyboard slide away. This is the in-app (foregrounded) ring path on
        // both platforms; Android's over-lock ring is a separate native activity
        // (IncomingCallActivity) with no Flutter keyboard in play, so it needs
        // nothing here.
        if (live && !wasLive) {
          FocusManager.instance.primaryFocus?.unfocus();
        }
        // React to the call ending: show "Call ended" for a beat, then clear.
        if (next == CallStatus.ended && _dismissTimer == null) {
          _dismissTimer = Timer(const Duration(milliseconds: 1400), () {
            _dismissTimer = null;
            if (mounted) ref.read(callControllerProvider).dismiss();
          });
        }
      },
    );

    final session =
        ref.watch(callControllerProvider.select((c) => c.current));

    // Minimized only while the call is live-and-minimizable. An ended call, or
    // anything that rings in, always shows full screen.
    final minimized = session != null &&
        _minimizedCallId == session.callId &&
        (session.status == CallStatus.outgoingRinging ||
            session.status == CallStatus.connecting ||
            session.status == CallStatus.active);
    final bannerHeight =
        MediaQuery.of(context).padding.top + CallBanner.contentHeight;

    return Stack(
      children: [
        // The app stays at the SAME position in the tree whether or not the call
        // is minimized (only the padding changes), so toggling never remounts the
        // navigator and loses the user's place. While minimized the banner owns
        // the status-bar inset, so the app below must not pad for it again.
        Padding(
          padding: EdgeInsets.only(top: minimized ? bannerHeight : 0),
          child: MediaQuery.removePadding(
            context: context,
            removeTop: minimized,
            child: widget.child,
          ),
        ),
        if (session != null && minimized)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: CallBanner(
              session: session,
              controller: ref.read(callControllerProvider),
              onExpand: () => setState(() => _minimizedCallId = null),
            ),
          )
        else if (session != null)
          Positioned.fill(
            // A new key per call so the screen's timer state resets between calls.
            child: CallScreen(
              key: ValueKey(session.callId),
              session: session,
              onMinimize: () =>
                  setState(() => _minimizedCallId = session.callId),
            ),
          ),
      ],
    );
  }
}
