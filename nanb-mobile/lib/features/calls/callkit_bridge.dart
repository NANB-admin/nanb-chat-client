import 'dart:async';

import '../../core/push/voip_push_channel.dart';
import 'call_controller.dart';
import 'models/call_session.dart';

/// Joins the iOS system call UI (CallKit, fed by PushKit) to the app's
/// [CallController].
///
/// Split out of the controller on purpose: the state machine stays free of
/// platform channels (and unit-testable), while this owns the one-way
/// translation in each direction.
///
/// **Native → Dart.** A VoIP push has already been reported to CallKit
/// natively by the time we hear about it (iOS requires that, and the engine may
/// not have existed yet), so our job is only to make the app agree: resolve
/// which conversation it is — opening the inlined sealed blob, which the
/// *server* cannot do — put [CallController] into its from-push placeholder
/// ring, and hand CallKit the real caller name to display. Answer/hang-up taps
/// on the system UI drive [CallController.accept] / `decline` / `hangup`.
///
/// **Dart → native.** Whenever the app's call ends, the system call UI must be
/// dismissed, or a phantom ring stays on screen with nothing behind it. That
/// includes the cases where we decline to ring at all (a blocked or
/// non-callable peer) — the push already rang the phone by then.
class CallKitBridge {
  CallKitBridge({
    required VoipPushChannel channel,
    required CallController Function() controller,
    required Future<String?> Function(Map<String, String> payload) resolveConversationId,
    required Future<String> Function(String conversationId) resolveCallerName,
    required bool Function(String conversationId) shouldRing,
  })  : _channel = channel,
        _controller = controller,
        _resolveConversationId = resolveConversationId,
        _resolveCallerName = resolveCallerName,
        _shouldRing = shouldRing;

  final VoipPushChannel _channel;
  final CallController Function() _controller;
  final Future<String?> Function(Map<String, String> payload) _resolveConversationId;
  final Future<String> Function(String conversationId) _resolveCallerName;
  final bool Function(String conversationId) _shouldRing;

  final List<StreamSubscription<void>> _subs = [];

  /// Serialises native events. Handling an `incomingCall` is ASYNC (it decrypts
  /// the sealed blob to find the conversation), and on the cold-launch replay
  /// the buffered `answerCall` follows it immediately — so without this the
  /// answer ran against a state machine that had no session yet and was
  /// silently dropped. That is precisely the "answered from the lock screen and
  /// nothing happened" case CallKit exists to fix, so the ordering is
  /// load-bearing, not tidiness.
  Future<void> _events = Future<void>.value();

  void _enqueue(Future<void> Function() work) {
    _events = _events.then((_) => work()).catchError((_) {/* keep the queue alive */});
  }

  /// True while the SYSTEM is ringing this call. The app must then stay silent:
  /// CallKit plays the ringtone, and the in-app tone on top of it is a double
  /// ring. Cleared as soon as the call ends (or was never CallKit's).
  bool get systemIsRinging => _systemRinging;
  bool _systemRinging = false;

  Future<void> start() async {
    _subs.add(_channel.incomingCalls
        .listen((p) => _enqueue(() => _onIncomingCall(p))));
    _subs.add(_channel.answers.listen((_) => _enqueue(() async => _onAnswer())));
    _subs.add(_channel.ends.listen((_) => _enqueue(() async => _onEnd())));
    // Attaches the handler AND replays anything buffered before this engine
    // existed — the cold-launch "answered from the lock screen" path.
    await _channel.start();
  }

  Future<void> _onIncomingCall(Map<String, String> payload) async {
    _systemRinging = true;
    final conversationId = await _resolveConversationId(payload);
    // Can't tell which conversation this is (not addressed to us, a corrupt
    // blob, or keys we don't hold yet), or we positively know it must not ring.
    // Either way the phone is ALREADY ringing — the native side reported to
    // CallKit before any app code ran — so the only correct move is to stop it.
    if (conversationId == null ||
        conversationId.isEmpty ||
        !_shouldRing(conversationId)) {
      // ignore: avoid_print
      print('NANBCALL dismissing system ring: '
          '${conversationId == null || conversationId.isEmpty ? 'unresolved conversation' : 'must not ring'}');
      await _dismissSystemCall();
      return;
    }
    final caller = await _resolveCallerName(conversationId);
    _controller().ringFromPush(
      conversationId: conversationId,
      callerName: caller,
    );
    await _channel.updateCaller(caller);
  }

  void _onAnswer() {
    final c = _controller();
    // Only a ringing call can be answered; anything else means the state
    // machine already moved on (the caller gave up, another device won).
    if (c.current?.status == CallStatus.incomingRinging) {
      unawaited(c.accept());
    }
  }

  void _onEnd() {
    // The system UI is already gone — do NOT call back into it (that would
    // recurse through onCallEnded). Just mirror the decision into the app.
    _systemRinging = false;
    final c = _controller();
    final s = c.current;
    if (s == null || !s.isLive) return;
    if (s.status == CallStatus.incomingRinging) {
      unawaited(c.decline());
    } else {
      unawaited(c.hangup());
    }
  }

  /// Called when the app's call ends, from any cause, so the system UI goes
  /// with it. Idempotent — ending a call the system doesn't have is a no-op.
  Future<void> onAppCallEnded() => _dismissSystemCall();

  Future<void> _dismissSystemCall() async {
    _systemRinging = false;
    await _channel.endCall();
  }

  Future<void> dispose() async {
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
  }
}
