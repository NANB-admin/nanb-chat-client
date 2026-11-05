import 'dart:async';

import 'package:flutter/foundation.dart';

import 'call_media_engine.dart';
import 'call_transport.dart';
import 'local_ice_outbox.dart';
import 'models/call_signal.dart';
import 'models/call_session.dart';
import 'remote_ice_buffer.dart';

/// The 1:1 call state machine — the brain of calling, deliberately decoupled
/// from WebRTC, the WebSocket, and the UI so it is fully unit-testable.
///
/// It owns **one** [CallSession] at a time (1:1 only; no group calls). It:
///   - places/accepts/declines/hangs-up calls,
///   - drives the SDP/ICE handshake against an injected [CallMediaEngine],
///   - sends signaling via an injected [CallTransport],
///   - enforces the "can only call an **accepted, non-blocked 1:1**" rule via
///     [canCall] (mirrors the message-request trust model — an invite from a
///     non-accepted contact is dropped silently).
///
/// See `docs/voice-calls-design.md` for the full protocol.
class CallController extends ChangeNotifier {
  CallController({
    required CallMediaEngine Function() engineFactory,
    required CallTransport transport,
    required bool Function(String conversationId) canCall,
    required String Function() selfDeviceId,
    required String Function() generateCallId,
    void Function(CallSession ended)? onCallEnded,
    DateTime Function()? clock,
    Duration pushRingTimeout = const Duration(seconds: 60),
    Duration acceptedAwaitingInviteTimeout = const Duration(seconds: 90),
    Duration outgoingRingTimeout = const Duration(seconds: 60),
    Duration iceRecoveryWindow = const Duration(seconds: 20),
    Duration mediaDropWindow = const Duration(seconds: 12),
    Duration connectTimeout = const Duration(seconds: 60),
    Duration connectRetryInterval = const Duration(seconds: 15),
  })  : _engineFactory = engineFactory,
        _transport = transport,
        _canCall = canCall,
        _selfDeviceId = selfDeviceId,
        _generateCallId = generateCallId,
        _onCallEnded = onCallEnded,
        _now = clock ?? DateTime.now,
        _pushRingTimeout = pushRingTimeout,
        _acceptedAwaitingInviteTimeout = acceptedAwaitingInviteTimeout,
        _outgoingRingTimeout = outgoingRingTimeout,
        _iceRecoveryWindow = iceRecoveryWindow,
        _mediaDropWindow = mediaDropWindow,
        _connectTimeout = connectTimeout,
        _connectRetryInterval = connectRetryInterval;

  final CallMediaEngine Function() _engineFactory;
  final CallTransport _transport;
  final bool Function(String conversationId) _canCall;
  final String Function() _selfDeviceId;
  final String Function() _generateCallId;
  final void Function(CallSession ended)? _onCallEnded;
  final DateTime Function() _now;

  /// How long a from-push placeholder ring waits for the real invite to catch
  /// up before giving up as "missed".
  final Duration _pushRingTimeout;

  /// Once the user has ANSWERED a from-push placeholder (but the real invite
  /// still hasn't caught up), how long to keep waiting for it to reconcile +
  /// connect before giving up as "failed". Longer than [_pushRingTimeout]: a
  /// slow Tor re-bootstrap after waking, plus passcode entry on a locked device,
  /// can outlast the ring window — and an answered call must not drop as
  /// "missed". See [accept].
  final Duration _acceptedAwaitingInviteTimeout;

  /// How long an OUTGOING call rings the caller before auto-cancelling as a
  /// no-answer (otherwise it would ring forever waiting for the callee).
  final Duration _outgoingRingTimeout;

  /// Fires if our outgoing call is never answered within [_outgoingRingTimeout].
  Timer? _outgoingRingTimer;

  CallSession? _session;
  CallMediaEngine? _engine;
  StreamSubscription<Map<String, dynamic>>? _iceSub;
  StreamSubscription<CallConnectionState>? _connSub;

  /// ICE-restart recovery (reliability): a relay-only call has no fallback
  /// candidates, so a single slow/failed TURN allocation otherwise drops the
  /// call. On a connection `failed` the CALLER re-offers with fresh ICE (up to
  /// [_maxIceRestarts] times); the CALLEE waits for that re-offer rather than
  /// ending, giving up only after [_iceRecoveryWindow]. Reset on `connected`.
  int _iceRestarts = 0;
  static const int _maxIceRestarts = 2;
  Timer? _iceRecoveryTimer;
  final Duration _iceRecoveryWindow;

  /// Liveness watchdog for an ACTIVE call. WebRTC surfaces a vanished peer as
  /// `disconnected` (the engine maps it to [CallConnectionState.connecting]) and
  /// may never escalate to `failed` — a silently-killed peer, or a relay path
  /// that stays nominally up. Without a deadline the call shows "connected"
  /// forever after the other side ended/died — the "I hung up but the peer
  /// never knew" bug. Armed when an active call leaves `connected`; cancelled
  /// the moment it returns. On expiry the drop is escalated like a hard
  /// `failed` (caller re-offers with fresh ICE; a gone peer ends the call).
  Timer? _mediaDropTimer;
  final Duration _mediaDropWindow;

  /// Bounds the CONNECTING phase (accept → media connected). The ring timeouts
  /// only cover the pre-accept ringing phase and the media-drop watchdog only an
  /// already-active call, so without this a call that never establishes (a dead
  /// TURN relay, a lost offer/answer, ICE that never completes) would hang in
  /// "Connecting…" indefinitely. Armed when a side enters `connecting`, cancelled
  /// on `connected`; on expiry the call ends as failed so the user can retry.
  ///
  /// Sized for the SLOW path, not the fast one: the window it bounds spans the
  /// accept signal, the TURN-credential fetch, the peer's offer/answer, and ICE
  /// — every one of those a Tor round-trip on a possibly-cold circuit. At the
  /// old 30s a cold-Tor call reliably ran out of clock mid-negotiation and ended
  /// as `failed` before it could ever connect. 60s matches [_outgoingRingTimeout]
  /// and stays inside [_acceptedAwaitingInviteTimeout] (90s), so the phases stay
  /// ordered: reconcile → connect → give up.
  Timer? _connectTimer;
  final Duration _connectTimeout;

  /// Set when the user answers a from-push placeholder ring BEFORE the real
  /// invite has caught up; the accept fires the moment [_onInvite] reconciles.
  bool _wantAcceptOnInvite = false;

  /// Fires if a from-push placeholder ring never reconciles with a real invite.
  Timer? _pushRingTimer;

  /// Conversations whose push ring the user DECLINED before the invite arrived,
  /// so the late invite is auto-declined instead of re-ringing. (conv → when.)
  final Map<String, DateTime> _pushDeclined = {};

  /// Call ids another of OUR devices already answered/declined (or the caller
  /// cancelled) — told to us by a stop-ring that can beat the invite itself, so
  /// the late invite must not ring. Bounded; oldest dropped first.
  final List<String> _stoppedCallIds = [];

  void _rememberStopped(String callId) {
    if (callId.isEmpty || _stoppedCallIds.contains(callId)) return;
    _stoppedCallIds.add(callId);
    if (_stoppedCallIds.length > 20) _stoppedCallIds.removeAt(0);
  }

  /// Mid-connect recovery. [_connectTimer] only GIVES UP; on its own a single
  /// lost signal (an offer, an answer, a candidate batch — each one E2EE submit
  /// that can fail after its retry budget) left the call in "Connecting…" for
  /// the whole window and then failed it: the "it just hangs, I drop and re-call
  /// and then it works" symptom. Every [_connectRetryInterval] while still
  /// connecting, the side that can unstick the handshake nudges it:
  ///  - caller, no answer yet → re-send the SAME offer (idempotent: the callee
  ///    re-sends its cached answer for a duplicate);
  ///  - caller, answered but ICE never connected → ICE-restart re-offer (fresh
  ///    candidates; bounded by [_maxIceRestarts]);
  ///  - callee, no offer yet → re-send the accept (the caller answers a
  ///    duplicate accept from the pinned device by re-sending its offer).
  /// Bounded by [_maxConnectRetries]; [_connectTimer] still has the final say.
  Timer? _connectRetryTimer;
  final Duration _connectRetryInterval;
  int _connectRetries = 0;
  static const int _maxConnectRetries = 3;

  /// Completes once the current engine's [CallMediaEngine.start] has returned.
  /// The callee starts its engine CONCURRENTLY with sending the accept, so the
  /// caller's offer can arrive while the engine is still fetching TURN
  /// credentials / acquiring the mic — before its peer connection exists. That
  /// offer used to throw (null peer connection) inside an unawaited handler and
  /// vanish, and the call hung. Handlers that touch the peer connection wait on
  /// this first.
  Completer<void>? _engineStarted;

  /// Caller's offer bookkeeping: the number + SDP of the CURRENT offer, and
  /// whether its answer has been applied. A re-sent offer keeps its number; an
  /// ICE restart bumps it, so a late answer to a superseded offer is dropped.
  int _offerSeq = 0;
  String? _currentOfferSdp;
  bool _answerApplied = false;

  /// Callee's offer bookkeeping: the last offer applied and our answer to it, so
  /// a DUPLICATE offer (the caller's retry) is answered from cache instead of
  /// renegotiating; and whether any offer has arrived (gates the accept retry).
  String? _lastRemoteOfferSdp;
  String? _lastLocalAnswerSdp;
  bool _offerReceived = false;

  /// Our candidates, held until the SDP they belong to is sent, then coalesced.
  late final LocalIceOutbox _localIce = LocalIceOutbox(send: _sendIceBatch);

  /// The peer's candidates, held until the remote description is applied.
  late final RemoteIceBuffer _remoteIce =
      RemoteIceBuffer(apply: _applyRemoteIce);

  /// The current call, or null when idle.
  CallSession? get current => _session;

  /// The live media engine for the current call, or null when idle. The in-call
  /// UI reads this to bind video renderers (it's the one WebRTC-coupled layer);
  /// the state machine itself never touches the engine's media types.
  CallMediaEngine? get engine => _engine;

  /// True while a live call exists — used to gate placing/accepting another.
  bool get isBusy => _session?.isLive ?? false;

  // ── Outbound: user actions ────────────────────────────────────────────────

  /// Place a call to [peerAccountId] in [conversationId]. No-op if already in a
  /// call or if the conversation isn't a callable (accepted, non-blocked) 1:1.
  Future<void> placeCall({
    required String conversationId,
    required String peerAccountId,
    required String peerUsername,
    CallMediaKind kind = CallMediaKind.audio,
  }) async {
    if (isBusy) return;
    if (!_canCall(conversationId)) return;

    final callId = _generateCallId();
    _session = CallSession(
      callId: callId,
      conversationId: conversationId,
      peerAccountId: peerAccountId,
      peerUsername: peerUsername,
      peerDeviceId: '', // resolved when a device accepts
      direction: CallDirection.outgoing,
      status: CallStatus.outgoingRinging,
      mediaKind: kind,
      startedAt: _now(),
    );
    notifyListeners();

    await _startEngine(isCaller: true);
    // Engine start may have failed (permission denied) and ended the call — only
    // ring the peer if we're still the live, ringing outgoing call.
    if (_session?.callId != callId ||
        _session?.status != CallStatus.outgoingRinging) {
      return;
    }
    try {
      await _transport.sendInvite(
        toAccountId: peerAccountId,
        signal: CallSignal.invite(
          callId: callId,
          mediaKind: kind,
          fromDeviceId: _selfDeviceId(),
        ),
      );
    } catch (_) {
      // The ring never left this device (offline, Tor mid-bootstrap, retry
      // budget spent), so the callee's phone will never ring. Fail NOW instead
      // of showing "Ringing…" into the void for the whole no-answer window —
      // and instead of throwing out of a user action, which left the session
      // stuck as `outgoingRinging` with nothing but that timer to clear it.
      await _end(CallEndReason.failed);
      return;
    }
    // No-answer guard: an outgoing call rings forever otherwise. After the
    // timeout, cancel it (hangup also cancels the callee's ring on all devices).
    //
    // Armed HERE, not before the setup above: the window has to be real ring
    // time. Started earlier, media acquisition plus the invite's own submit (a
    // Tor round trip, retried for up to ~19s on a transient failure) ate a large
    // and variable slice of it, so the caller gave up on a callee whose phone
    // had barely started ringing — "it never connects, I hang up and call
    // again".
    _outgoingRingTimer?.cancel();
    _outgoingRingTimer = Timer(_outgoingRingTimeout, () {
      if (_session?.status == CallStatus.outgoingRinging) unawaited(hangup());
    });
  }

  /// Ring IMMEDIATELY from a call push, before the real E2EE invite has been
  /// caught up + decrypted. The device was woken by a `push_kind:'call'` push;
  /// this paints the incoming-call UI from the push payload (caller name) so the
  /// phone rings without waiting on the fragile reconnect→catchup→decrypt chain.
  /// [_onInvite] reconciles it (fills in callId/peerDeviceId/peerAccountId) when
  /// the invite lands. No-op if a real call is already live or we're already
  /// ringing for this conversation.
  void ringFromPush({
    required String conversationId,
    required String callerName,
  }) {
    final s = _session;
    // ignore: avoid_print
    print('NANBCALL ringFromPush conv=$conversationId caller=$callerName '
        'curStatus=${s?.status} curAwaiting=${s?.awaitingInvite}');
    if (s != null && s.isLive && !s.awaitingInvite) {
      // ignore: avoid_print
      print('NANBCALL ringFromPush IGNORED (a real call is live)');
      return; // real call ongoing
    }
    if (s != null && s.isLive && s.conversationId == conversationId) {
      // ignore: avoid_print
      print('NANBCALL ringFromPush IGNORED (already ringing this conv)');
      return;
    }
    _pushDeclined.remove(conversationId); // a fresh ring supersedes an old decline
    _session = CallSession(
      callId: '',
      conversationId: conversationId,
      peerAccountId: '',
      peerUsername: callerName,
      peerDeviceId: '',
      direction: CallDirection.incoming,
      status: CallStatus.incomingRinging,
      mediaKind: CallMediaKind.audio,
      startedAt: _now(),
      awaitingInvite: true,
    );
    notifyListeners();
    // ignore: avoid_print
    print('NANBCALL ringFromPush -> placeholder RINGING (awaitingInvite)');
    // No-answer guard: if the invite never catches up (caller gave up, or a
    // stale push), stop ringing as "missed" instead of ringing forever.
    _pushRingTimer?.cancel();
    _pushRingTimer = Timer(_pushRingTimeout, () {
      if (_session?.awaitingInvite == true) unawaited(_end(CallEndReason.missed));
    });
  }

  /// Callee accepts the ringing call.
  Future<void> accept() async {
    final s = _session;
    if (s == null || s.status != CallStatus.incomingRinging) return;
    if (s.awaitingInvite) {
      // The real invite hasn't been caught up yet (cold-start from push). Show
      // "connecting" and accept the moment [_onInvite] reconciles.
      _wantAcceptOnInvite = true;
      _session = s.copyWith(status: CallStatus.connecting);
      notifyListeners();
      // The user ANSWERED, so the no-answer "missed" ring deadline no longer
      // applies — replace it with the longer answered-but-awaiting-invite window
      // (a slow Tor re-bootstrap after waking + passcode entry on a locked device
      // can outlast the ring window). If the invite genuinely never reconciles,
      // end as `failed`, not `missed`. Cancelled on reconcile by [_onInvite],
      // which then arms the connect timeout for the media phase.
      _pushRingTimer?.cancel();
      _pushRingTimer = Timer(_acceptedAwaitingInviteTimeout, () {
        if (_session?.awaitingInvite == true) {
          unawaited(_end(CallEndReason.failed));
        }
      });
      return;
    }
    _session = s.copyWith(status: CallStatus.connecting);
    notifyListeners();
    await _doAccept(s);
  }

  /// Sends the accept signal + starts the media engine as callee. Shared by
  /// [accept] and the [_onInvite] reconcile path (answer-before-invite).
  Future<void> _doAccept(CallSession s) async {
    _armConnectTimeout(); // bound the callee's connect phase (status: connecting)
    // We are the answering device: tell our OTHER devices to stop ringing now,
    // directly, instead of waiting for the caller to notice the accept.
    _stopSiblingRings(s);
    // Ship the accept and bring up local media CONCURRENTLY. The accept is a
    // full E2EE submit — a Tor round trip on a cold circuit — and the engine
    // needs nothing from it, so serialising the two simply added that whole leg
    // to every answer. The peer device is already pinned here, so any ICE this
    // gathers early is addressed correctly.
    Object? sendError;
    final accepted = _transport
        .sendToDevice(
          toAccountId: s.peerAccountId,
          toDeviceId: s.peerDeviceId,
          signal: CallSignal.accept(
            callId: s.callId,
            fromDeviceId: _selfDeviceId(),
          ),
        )
        .catchError((Object e) {
      sendError = e;
    });
    // Start as callee and wait for the caller's offer.
    await _startEngine(isCaller: false);
    await accepted;
    // The accept never left this device, so the caller will never send an offer
    // and nothing will ever arrive: fail NOW rather than holding the user on
    // "Connecting…" for the whole connect window. (Previously this threw out of
    // an unawaited handler and the call just hung.)
    if (sendError != null && _session?.callId == s.callId) {
      await _end(CallEndReason.failed);
      return;
    }
    if (_session?.callId == s.callId) _armConnectRetry();
  }

  /// Callee declines the ringing call (the peer is told).
  Future<void> decline() async {
    final s = _session;
    if (s == null || s.status != CallStatus.incomingRinging) return;
    if (s.awaitingInvite) {
      // Declined before the invite caught up — we don't yet know the
      // callId/device to address a decline, so end locally and remember to
      // auto-decline the invite when it lands (else it would re-ring).
      _pushDeclined[s.conversationId] = _now();
      await _end(CallEndReason.declined);
      return;
    }
    // Stop ringing HERE, then tell the peer — see [hangup] for why the local
    // teardown must never wait on (or depend on) the signal landing.
    await _end(CallEndReason.declined);
    _stopSiblingRings(s);
    _signalDetached(() => _transport.sendToDevice(
          toAccountId: s.peerAccountId,
          toDeviceId: s.peerDeviceId,
          signal: CallSignal.decline(s.callId),
        ));
  }

  /// This device handled the ring (answered or declined it): stop it on this
  /// account's OTHER devices at once, over the own-devices channel, so a call
  /// rings everywhere but is answered — and connects — on exactly one device.
  /// The cancel names THIS device as the exception, so it can never tear down
  /// the device that answered. Detached: housekeeping for the siblings, never
  /// something the local call waits on.
  void _stopSiblingRings(CallSession s) {
    if (s.callId.isEmpty) return;
    _signalDetached(() => _transport.sendToOwnDevices(
          peerAccountId: s.peerAccountId,
          signal: CallSignal.cancel(s.callId, exceptDeviceId: _selfDeviceId()),
        ));
  }

  /// Either side ends a ringing/connecting/active call (the peer is told).
  Future<void> hangup() async {
    final s = _session;
    if (s == null || !s.isLive) return;
    // TEAR DOWN LOCALLY FIRST; the peer's copy of the decision is best-effort.
    //
    // Signalling is not a cheap local call: it rides the E2EE store-and-forward
    // path — an MLS encrypt plus a submit that queues on this conversation's
    // FIFO lock BEHIND every ICE-candidate send still in flight, and that
    // retries a transient failure for ~19s. Awaiting it before [_end] meant
    // "End call" did nothing visible for tens of seconds; and if the send THREW
    // (offline, Tor mid-bootstrap, retry budget spent) [_end] never ran at all,
    // so the tone kept playing and the call stayed live until the app was
    // killed. Ending a call is a local decision — make it locally, at once.
    final wasRingingOutgoing = s.direction == CallDirection.outgoing &&
        s.status == CallStatus.outgoingRinging;
    await _end(CallEndReason.hangup);
    if (s.peerDeviceId.isNotEmpty) {
      _signalDetached(() => _transport.sendToDevice(
            toAccountId: s.peerAccountId,
            toDeviceId: s.peerDeviceId,
            signal: CallSignal.hangup(s.callId),
          ));
    }
    // An outgoing call we abandon before it's answered is a cancel to the
    // ringing devices (no device has been pinned yet).
    if (wasRingingOutgoing) {
      _signalDetached(() => _transport.sendToAllDevices(
            toAccountId: s.peerAccountId,
            signal: CallSignal.cancel(s.callId),
          ));
    }
  }

  /// Fires a signal the local state machine must never WAIT on: teardown
  /// notices, ring-stop cancels, the informational `ringing` ack. Detached and
  /// error-swallowing — a signal that never lands costs the peer a watchdog
  /// timeout (media-drop / connect / ring), whereas blocking on it costs the
  /// USER a frozen call screen. Errors are absorbed here rather than left to
  /// surface as an unhandled async error.
  void _signalDetached(Future<void> Function() send) {
    unawaited(() async {
      try {
        await send();
      } catch (_) {/* best-effort */}
    }());
  }

  Future<void> setMicMuted(bool muted) async {
    final s = _session;
    if (s == null || !s.isLive) return;
    await _engine?.setMicMuted(muted);
    _session = s.copyWith(micMuted: muted);
    notifyListeners();
  }

  Future<void> setSpeakerOn(bool on) async {
    final s = _session;
    if (s == null || !s.isLive) return;
    await _engine?.setSpeakerOn(on);
    _session = s.copyWith(speakerOn: on);
    notifyListeners();
  }

  /// Flip the local camera (front ↔ back). Video calls only.
  Future<void> switchCamera() async {
    final s = _session;
    if (s == null || !s.isLive || s.mediaKind != CallMediaKind.video) return;
    await _engine?.switchCamera();
    _session = s.copyWith(usingFrontCamera: !s.usingFrontCamera);
    notifyListeners();
  }

  /// Turn the local camera on/off mid-call (the call stays a video call; the
  /// peer just sees black). Video calls only.
  Future<void> setCameraEnabled(bool enabled) async {
    final s = _session;
    if (s == null || !s.isLive || s.mediaKind != CallMediaKind.video) return;
    await _engine?.setCameraEnabled(enabled);
    _session = s.copyWith(cameraEnabled: enabled);
    notifyListeners();
  }

  /// Clears a terminal ([CallStatus.ended]) session so the UI can dismiss.
  void dismiss() {
    if (_session?.status == CallStatus.ended) {
      _session = null;
      notifyListeners();
    }
  }

  // ── Inbound: signals from the peer (dispatched by the wiring layer) ────────

  /// Handle an inbound [sig] from ([fromAccountId], [fromDeviceId]).
  /// [conversationId] and [peerUsername] are required for an `invite` (to apply
  /// the permission rule and label the incoming-call UI); ignored otherwise.
  Future<void> handleSignal(
    CallSignal sig, {
    required String fromAccountId,
    required String fromDeviceId,
    String? conversationId,
    String? peerUsername,
  }) async {
    switch (sig.type) {
      case CallSignalType.invite:
        await _onInvite(sig, fromAccountId, fromDeviceId, conversationId,
            peerUsername);
      case CallSignalType.ringing:
        // Informational — the outgoing UI already shows "ringing". No-op.
        break;
      case CallSignalType.accept:
        await _onAccept(sig, fromDeviceId);
      case CallSignalType.offer:
        await _onOffer(sig);
      case CallSignalType.answer:
        await _onAnswer(sig);
      case CallSignalType.ice:
        await _onIce(sig);
      case CallSignalType.decline:
        if (_matches(sig) && _session!.direction == CallDirection.outgoing) {
          await _end(sig.reason == CallEndReason.busy
              ? CallEndReason.busy
              : CallEndReason.declined);
        }
      case CallSignalType.cancel:
        // "Answered elsewhere" exclusion: when the callee's first device
        // accepts, the caller stops the ring on the peer's OTHER devices with a
        // cancel that names the WINNING device. The transport fans that cancel
        // to every peer device, so it also reaches the winner — which is exactly
        // the device that just accepted. If this cancel names US as the winner,
        // ignore it (tearing down here is the "answered, then call vanishes"
        // bug). A give-up cancel carries no device id and still tears us down.
        // (Empty ids never match: an unset own id must not swallow a real cancel.)
        if (sig.fromDeviceId != null &&
            sig.fromDeviceId!.isNotEmpty &&
            sig.fromDeviceId == _selfDeviceId()) {
          break;
        }
        // Remembered so an invite that arrives AFTER this stop-ring (the sibling
        // that answered can beat the invite to us) doesn't ring a call that is
        // already handled.
        _rememberStopped(sig.callId);
        // Otherwise a cancel means the CALLER gave up (ring timeout, or hung up
        // before we connected), or another of the peer's devices won the race.
        // A callee that's ringing OR has accepted but not yet connected
        // (connecting) must tear down. Previously a connecting callee ignored
        // the cancel and hung until its own connect timeout — the "I answered,
        // the caller had already given up (a slow accept never reached them),
        // call stuck connecting" bug. An ACTIVE call ignores a stale cancel (the
        // caller sends hangup once connected). A from-push placeholder (no callId
        // yet) matches by convo.
        if (_matchesTeardown(sig, conversationId) &&
            _session!.direction == CallDirection.incoming &&
            (_session!.status == CallStatus.incomingRinging ||
                _session!.status == CallStatus.connecting)) {
          await _end(CallEndReason.cancelled);
        }
      case CallSignalType.hangup:
        if (_matchesTeardown(sig, conversationId)) {
          await _end(CallEndReason.hangup);
        }
    }
  }

  Future<void> _onInvite(
    CallSignal sig,
    String fromAccountId,
    String fromDeviceId,
    String? conversationId,
    String? peerUsername,
  ) async {
    // Another of our devices already answered/declined this call (or the caller
    // cancelled it) and that stop-ring beat the invite here: don't ring.
    if (_stoppedCallIds.contains(sig.callId)) return;
    // The user already DECLINED this conversation's push ring before the invite
    // caught up → auto-decline the late invite instead of re-ringing.
    if (conversationId != null && _wasRecentlyDeclined(conversationId)) {
      _pushDeclined.remove(conversationId);
      await _transport.sendToDevice(
        toAccountId: fromAccountId,
        toDeviceId: fromDeviceId,
        signal: CallSignal.decline(sig.callId),
      );
      return;
    }
    // Reconcile a from-push placeholder ring for this conversation: fill in the
    // real identifiers (callId, peer device/account) rather than treating the
    // already-showing ring as "busy" or starting a second session.
    // ignore: avoid_print
    print('NANBCALL _onInvite callId=${sig.callId} conv=$conversationId '
        'placeholder=${_session?.awaitingInvite == true}');
    final placeholder = _session;
    if (placeholder != null &&
        placeholder.awaitingInvite &&
        placeholder.isLive &&
        placeholder.conversationId == conversationId) {
      _pushRingTimer?.cancel();
      final accepting = _wantAcceptOnInvite;
      // ignore: avoid_print
      print('NANBCALL _onInvite RECONCILED placeholder (accepting=$accepting)');
      _session = CallSession(
        callId: sig.callId,
        conversationId: conversationId!,
        peerAccountId: fromAccountId,
        peerUsername: peerUsername ?? placeholder.peerUsername,
        peerDeviceId: fromDeviceId,
        direction: CallDirection.incoming,
        status: accepting ? CallStatus.connecting : CallStatus.incomingRinging,
        mediaKind: sig.mediaKind ?? CallMediaKind.audio,
        startedAt: placeholder.startedAt,
      );
      notifyListeners();
      // Tell the caller a device is ringing (their UI shows "ringing").
      // DETACHED: it is informational only, and this is the answer-before-invite
      // path — the user has already tapped Accept, so making the accept wait out
      // a whole E2EE submit of a cosmetic signal is the worst possible place to
      // spend a Tor round trip.
      _signalDetached(() => _transport.sendToDevice(
            toAccountId: fromAccountId,
            toDeviceId: fromDeviceId,
            signal: CallSignal.ringing(sig.callId),
          ));
      if (accepting) {
        _wantAcceptOnInvite = false;
        await _doAccept(_session!);
      }
      return;
    }
    // A re-delivery of the invite for the call we already hold (stored-path
    // redelivery / catchup overlap). Without this it fell through to `isBusy`
    // and busy-declined OUR OWN call, killing it on the caller's side.
    if (_session?.isLive == true && _session!.callId == sig.callId) return;
    await _resolveSamePeerInvite(sig, fromAccountId, conversationId);
    final afterResolve = _session;
    if (afterResolve != null &&
        afterResolve.isLive &&
        afterResolve.direction == CallDirection.outgoing &&
        afterResolve.status == CallStatus.outgoingRinging &&
        afterResolve.conversationId == conversationId &&
        afterResolve.peerAccountId == fromAccountId) {
      return; // glare, and OUR call won — the peer yields when ours reaches it
    }
    // Already in a call → tell them we're busy (auto-decline).
    if (isBusy) {
      await _transport.sendToDevice(
        toAccountId: fromAccountId,
        toDeviceId: fromDeviceId,
        signal: CallSignal.decline(sig.callId, reason: CallEndReason.busy),
      );
      return;
    }
    // Permission rule: only ring for an accepted, non-blocked 1:1. Otherwise
    // drop silently (same as a message request from a stranger).
    if (conversationId == null || !_canCall(conversationId)) return;

    _session = CallSession(
      callId: sig.callId,
      conversationId: conversationId,
      peerAccountId: fromAccountId,
      peerUsername: peerUsername ?? '',
      peerDeviceId: fromDeviceId,
      direction: CallDirection.incoming,
      status: CallStatus.incomingRinging,
      mediaKind: sig.mediaKind ?? CallMediaKind.audio,
      startedAt: _now(),
    );
    notifyListeners();

    // Informational only (the caller's UI shows "ringing"), and detached for the
    // same reason as above: the user can tap Accept at any moment and [accept]
    // must not queue behind a cosmetic signal on the conversation's FIFO lock.
    _signalDetached(() => _transport.sendToDevice(
          toAccountId: fromAccountId,
          toDeviceId: fromDeviceId,
          signal: CallSignal.ringing(sig.callId),
        ));
  }

  /// An invite from the SAME peer, in the SAME conversation, while we hold a
  /// not-yet-active session with them under a DIFFERENT call id. Previously
  /// this auto-declined as `busy`, which is exactly wrong in both cases:
  ///  - **Glare** (we are ringing them as they ring us): both sides replied
  ///    busy and BOTH calls died. Resolved deterministically — the smaller call
  ///    id survives. The loser drops its own outgoing call and rings the winner's
  ///    invite; the winner ignores the loser's invite (the caller of this
  ///    returns early when our outgoing call is still standing).
  ///  - **Re-dial** (the peer gave up on a stuck attempt and called again, but
  ///    their cancel never reached us): the old attempt — still ringing or stuck
  ///    connecting — is stale. Holding on to it made every re-dial bounce off
  ///    "busy" until our own connect timeout freed us. The new invite
  ///    supersedes it.
  /// An ACTIVE call is never superseded (that stays a busy decline).
  Future<void> _resolveSamePeerInvite(
    CallSignal sig,
    String fromAccountId,
    String? conversationId,
  ) async {
    final cur = _session;
    if (cur == null ||
        !cur.isLive ||
        conversationId == null ||
        cur.conversationId != conversationId ||
        cur.peerAccountId != fromAccountId ||
        cur.callId == sig.callId ||
        cur.status == CallStatus.active) {
      return;
    }
    if (cur.direction == CallDirection.outgoing &&
        cur.status == CallStatus.outgoingRinging) {
      if (cur.callId.compareTo(sig.callId) < 0) return; // ours wins
      _signalDetached(() => _transport.sendToAllDevices(
            toAccountId: cur.peerAccountId,
            signal: CallSignal.cancel(cur.callId),
          ));
    }
    await _end(CallEndReason.cancelled);
  }

  Future<void> _onAccept(CallSignal sig, String fromDeviceId) async {
    final s = _session;
    // Caller side, first accept wins. A second accept (another device) is
    // cancelled.
    if (s == null ||
        s.callId != sig.callId ||
        s.direction != CallDirection.outgoing) {
      return;
    }
    // The accepting device. Its self-declared id can arrive empty — a freshly
    // signed-in device may accept before its controller has learned its own id —
    // and an empty peer id made every offer send a silent no-op. The
    // transport-level sender id is authenticated, so prefer it.
    final winnerDeviceId =
        fromDeviceId.isNotEmpty ? fromDeviceId : (sig.fromDeviceId ?? '');
    if (s.status != CallStatus.outgoingRinging) {
      // The WINNING device accepting again: its accept-retry fired because our
      // offer never reached it. Re-send the current offer rather than treating
      // it as a losing device (which would only cancel it).
      if (winnerDeviceId == s.peerDeviceId) {
        if (s.status == CallStatus.connecting) unawaited(_sendCurrentOffer());
        return;
      }
      // A second device also accepted after the first already won
      // (s.peerDeviceId). Cancel the late accepter, but exclude the winner so
      // the fan-out doesn't tear the connected/connecting winner down too.
      await _transport.sendToDevice(
        toAccountId: s.peerAccountId,
        toDeviceId: fromDeviceId,
        signal: CallSignal.cancel(s.callId, exceptDeviceId: s.peerDeviceId),
      );
      return;
    }
    _session = s.copyWith(
      status: CallStatus.connecting,
      peerDeviceId: winnerDeviceId,
    );
    notifyListeners();
    _armConnectTimeout(); // bound the caller's connect phase
    // Negotiate with the winning device FIRST. The offer is the only thing that
    // advances the call; the stop-ring fan-out below is a full E2EE submit that
    // queues on the SAME per-conversation FIFO lock, so sending it first put an
    // entire round trip (a Tor one, on a cold circuit) between the accept and
    // the offer on every call — pure dead time in the window the user reads as
    // "Connecting…".
    await _awaitEngineStarted();
    final engine = _engine;
    if (engine == null || _session?.callId != s.callId) return;
    final String offer;
    try {
      offer = await engine.createOffer();
    } catch (_) {
      await _end(CallEndReason.failed);
      return;
    }
    if (_session?.callId != s.callId) return;
    _offerSeq = 1;
    _currentOfferSdp = offer;
    _answerApplied = false;
    // A failed send is NOT fatal here: the connect-retry watchdog re-sends it.
    await _sendCurrentOffer();
    _armConnectRetry();
    // Now stop the ring on the peer's OTHER devices — but exclude the winner
    // (the device that just accepted, now `connecting`): the transport fans this
    // out to every peer device, so without the exclusion the accepting device
    // would receive its own stop-ring cancel and tear itself down (the
    // "answered, then call vanishes" bug). Detached: it is housekeeping for the
    // devices that LOST the race, and nothing here waits on it.
    _signalDetached(() => _transport.sendToAllDevices(
          toAccountId: s.peerAccountId,
          signal: CallSignal.cancel(s.callId, exceptDeviceId: winnerDeviceId),
        ));
  }

  Future<void> _onOffer(CallSignal sig) async {
    final s = _session;
    if (s == null ||
        s.callId != sig.callId ||
        s.direction != CallDirection.incoming ||
        _engine == null) {
      return;
    }
    await _awaitEngineStarted();
    final engine = _engine;
    if (engine == null || _session?.callId != s.callId) return;
    _offerReceived = true;
    final sdp = sig.sdp!;
    if (sdp == _lastRemoteOfferSdp) {
      // The caller's offer retry — we already answered (or are answering) this
      // exact offer. Re-send the cached answer; never renegotiate a duplicate.
      final cached = _lastLocalAnswerSdp;
      if (cached != null) await _sendAnswer(s, cached, sig.seq);
      return;
    }
    _lastRemoteOfferSdp = sdp;
    _lastLocalAnswerSdp = null;
    // Candidates produced by this answer must not overtake it, and the peer's
    // candidates for this offer must wait until it is applied.
    _localIce.hold();
    _remoteIce.hold();
    final String answer;
    try {
      answer = await engine.createAnswer(sdp);
    } catch (_) {
      _lastRemoteOfferSdp = null;
      // A bad initial offer can never connect; a bad RE-offer leaves the
      // established media as it was.
      if (_session?.callId == s.callId &&
          _session?.status != CallStatus.active) {
        await _end(CallEndReason.failed);
      }
      return;
    }
    if (_session?.callId != s.callId) return;
    _lastLocalAnswerSdp = answer;
    await _remoteIce.release();
    await _sendAnswer(s, answer, sig.seq);
  }

  /// Sends [answer] (echoing the offer's [seq]) and, once it is on the wire,
  /// lets the candidates it produced follow it. A failed send is absorbed: the
  /// caller's offer retry brings us back here to re-send it.
  Future<void> _sendAnswer(CallSession s, String answer, int? seq) async {
    try {
      await _transport.sendToDevice(
        toAccountId: s.peerAccountId,
        toDeviceId: s.peerDeviceId,
        signal: CallSignal.answer(callId: s.callId, sdp: answer, seq: seq),
      );
    } catch (_) {
      return;
    }
    if (_session?.callId == s.callId) _localIce.release();
  }

  Future<void> _onAnswer(CallSignal sig) async {
    final s = _session;
    if (s == null ||
        s.callId != sig.callId ||
        s.direction != CallDirection.outgoing ||
        _engine == null) {
      return;
    }
    await _awaitEngineStarted();
    final engine = _engine;
    if (engine == null || _session?.callId != s.callId) return;
    // An answer to a SUPERSEDED offer (an ICE restart has since replaced it).
    // A peer that predates offer numbering echoes none — accept that.
    if (sig.seq != null && sig.seq != _offerSeq) return;
    // A duplicate (the callee re-answering our offer retry), or no offer out.
    if (_answerApplied || _currentOfferSdp == null) return;
    _answerApplied = true;
    try {
      await engine.acceptAnswer(sig.sdp!);
    } catch (_) {
      _answerApplied = false; // a later copy of the answer may still apply
      return;
    }
    if (_session?.callId != s.callId) return;
    await _remoteIce.release();
    // The handshake is done; give ICE a fresh interval before the watchdog
    // decides it is stuck and restarts it.
    _armConnectRetry();
  }

  Future<void> _onIce(CallSignal sig) async {
    if (!_matches(sig)) return;
    for (final c in sig.iceCandidates) {
      await _remoteIce.add(c);
    }
  }

  Future<void> _applyRemoteIce(Map<String, dynamic> candidate) async {
    final engine = _engine;
    if (engine == null) return;
    await engine.addRemoteIce(candidate);
  }

  Future<void> _awaitEngineStarted() async {
    final started = _engineStarted;
    if (started != null && !started.isCompleted) await started.future;
  }

  // ── Engine glue ───────────────────────────────────────────────────────────

  Future<void> _startEngine({required bool isCaller}) async {
    // Fresh ICE-recovery budget for this call.
    _iceRestarts = 0;
    _iceRecoveryTimer?.cancel();
    _iceRecoveryTimer = null;
    _resetNegotiation();
    final started = Completer<void>();
    _engineStarted = started;
    final engine = _engineFactory();
    _engine = engine;
    _iceSub = engine.localIceCandidates.listen(_onLocalIce);
    _connSub = engine.connectionState.listen(_onConnState);
    try {
      await engine.start(
        isCaller: isCaller,
        video: _session?.mediaKind == CallMediaKind.video,
      );
    } catch (error, stackTrace) {
      // Media acquisition failed — most often the user denied the camera/mic
      // permission. End cleanly instead of hanging forever in "connecting".
      // ignore: avoid_print
      print('NANBCALL media startup failed: $error\n$stackTrace');
      started.complete();
      await _end(CallEndReason.failed);
      return;
    }
    started.complete();
    // The engine (and, for video, its renderers + local preview) now exists —
    // notify so the in-call UI can bind to it. Harmless for audio calls.
    notifyListeners();
  }

  /// Clears every piece of per-negotiation state, so nothing from a previous
  /// (possibly stuck) attempt can leak into the next call.
  void _resetNegotiation() {
    _localIce.clear();
    _remoteIce.clear();
    _offerSeq = 0;
    _currentOfferSdp = null;
    _answerApplied = false;
    _lastRemoteOfferSdp = null;
    _lastLocalAnswerSdp = null;
    _offerReceived = false;
    _connectRetries = 0;
    _connectRetryTimer?.cancel();
    _connectRetryTimer = null;
  }

  void _onLocalIce(Map<String, dynamic> candidate) {
    final s = _session;
    if (s == null || !s.isLive) return;
    _localIce.add(candidate); // gated until our SDP is on the wire
  }

  Future<void> _sendIceBatch(List<Map<String, dynamic>> batch) async {
    final s = _session;
    if (s == null || !s.isLive || s.peerDeviceId.isEmpty) return;
    await _transport.sendToDevice(
      toAccountId: s.peerAccountId,
      toDeviceId: s.peerDeviceId,
      signal: CallSignal.iceBatch(callId: s.callId, candidates: batch),
    );
  }

  /// Caller: sends the CURRENT offer ([_currentOfferSdp] / [_offerSeq]) to the
  /// pinned device; once it is on the wire, lets its candidates follow. Returns
  /// whether it was sent. Used for the first offer, retries, and re-offers.
  Future<bool> _sendCurrentOffer() async {
    final s = _session;
    final sdp = _currentOfferSdp;
    if (s == null || !s.isLive || sdp == null || s.peerDeviceId.isEmpty) {
      return false;
    }
    try {
      await _transport.sendToDevice(
        toAccountId: s.peerAccountId,
        toDeviceId: s.peerDeviceId,
        signal: CallSignal.offer(callId: s.callId, sdp: sdp, seq: _offerSeq),
      );
    } catch (_) {
      return false;
    }
    if (_session?.callId != s.callId) return false;
    _localIce.release();
    return true;
  }

  /// (Re)starts the [_connectRetryInterval] nudge while the call is connecting.
  void _armConnectRetry() {
    _connectRetryTimer?.cancel();
    _connectRetryTimer = null;
    final s = _session;
    if (s == null || !s.isLive || s.status != CallStatus.connecting) return;
    _connectRetryTimer = Timer(_connectRetryInterval, _onConnectRetry);
  }

  void _onConnectRetry() {
    _connectRetryTimer = null;
    final s = _session;
    if (s == null || !s.isLive || s.status != CallStatus.connecting) return;
    if (_connectRetries >= _maxConnectRetries) return;
    _connectRetries++;
    if (s.direction == CallDirection.outgoing) {
      if (!_answerApplied) {
        // ignore: avoid_print
        print('NANBCALL no answer on ${s.callId} — re-sending offer');
        unawaited(_sendCurrentOffer());
        _armConnectRetry();
        return;
      }
      if (_iceRestarts < _maxIceRestarts && _engine != null) {
        _iceRestarts++;
        unawaited(_attemptIceRestart(s)); // re-arms once the re-offer is out
      }
      return;
    }
    if (!_offerReceived) {
      // ignore: avoid_print
      print('NANBCALL no offer on ${s.callId} — re-sending accept');
      _signalDetached(() => _transport.sendToDevice(
            toAccountId: s.peerAccountId,
            toDeviceId: s.peerDeviceId,
            signal: CallSignal.accept(
              callId: s.callId,
              fromDeviceId: _selfDeviceId(),
            ),
          ));
      _armConnectRetry();
    }
  }

  void _onConnState(CallConnectionState state) {
    final s = _session;
    if (s == null || !s.isLive) return;
    switch (state) {
      case CallConnectionState.connected:
        // A successful (re)connect clears the ICE-recovery budget + timer and
        // the media-drop watchdog (this WAS a transient blip after all).
        _iceRestarts = 0;
        _iceRecoveryTimer?.cancel();
        _iceRecoveryTimer = null;
        _mediaDropTimer?.cancel();
        _mediaDropTimer = null;
        _connectTimer?.cancel();
        _connectTimer = null;
        _connectRetryTimer?.cancel();
        _connectRetryTimer = null;
        if (s.status != CallStatus.active) {
          _session = s.copyWith(
            status: CallStatus.active,
            connectedAt: _now(),
          );
          notifyListeners();
        }
      case CallConnectionState.failed:
        // An explicit failure supersedes the watchdog — handle it directly.
        _mediaDropTimer?.cancel();
        _mediaDropTimer = null;
        _handleIceFailure(s);
      case CallConnectionState.closed:
        if (s.status != CallStatus.ended) unawaited(_end(CallEndReason.hangup));
      case CallConnectionState.connecting:
        // `connecting` covers WebRTC's `disconnected` (the engine collapses it
        // here). On an ACTIVE call that means the media transport dropped: arm
        // the watchdog so a peer that vanished without escalating to `failed`
        // can't leave us "connected" forever.
        _armMediaDropWatchdog(s);
    }
  }

  /// Arms the [_mediaDropWindow] deadline when a live, active call loses its
  /// media transport. A genuine transient blip returns to `connected` (which
  /// cancels this) well inside the window; a real drop escalates exactly like a
  /// hard `failed` — the caller re-offers with fresh ICE (bounded by
  /// [_maxIceRestarts]), and a gone peer ends the call instead of hanging.
  void _armMediaDropWatchdog(CallSession s) {
    if (s.status != CallStatus.active) return;
    _mediaDropTimer ??= Timer(_mediaDropWindow, () {
      _mediaDropTimer = null;
      final live = _session;
      if (live != null && live.isLive && live.status == CallStatus.active) {
        _handleIceFailure(live);
      }
    });
  }

  /// Starts the [_connectTimeout] deadline for the CONNECTING phase. Cancels any
  /// prior timer (so a re-negotiation restarts the clock). On expiry, a call
  /// still stuck in `connecting` ends as failed — it never reached media.
  void _armConnectTimeout() {
    _connectTimer?.cancel();
    _connectTimer = Timer(_connectTimeout, () {
      _connectTimer = null;
      final s = _session;
      if (s != null && s.isLive && s.status == CallStatus.connecting) {
        unawaited(_end(CallEndReason.failed));
      }
    });
  }

  /// Recovers from an ICE `failed` instead of immediately dropping the call.
  /// A relay-only call has no fallback candidates, so a single slow/failed TURN
  /// allocation that we could recover with a fresh attempt would otherwise kill
  /// the call. The CALLER re-offers with fresh ICE (bounded by [_maxIceRestarts]);
  /// the CALLEE holds the call open waiting for that re-offer and gives up only
  /// after [_iceRecoveryWindow] (or sooner, when the caller — having exhausted
  /// its retries — hangs up).
  void _handleIceFailure(CallSession s) {
    if (s.direction == CallDirection.outgoing) {
      if (_iceRestarts < _maxIceRestarts &&
          _engine != null &&
          s.peerDeviceId.isNotEmpty) {
        _iceRestarts++;
        unawaited(_attemptIceRestart(s));
        return;
      }
      unawaited(_end(CallEndReason.failed));
    } else {
      _iceRecoveryTimer ??= Timer(_iceRecoveryWindow, () {
        // Fired without a reconnect — a successful reconnect cancels this timer
        // (in the `connected` branch), so reaching here means the peer never
        // recovered. End the call whether it failed mid-setup OR dropped while
        // active (an active call whose peer vanished must NOT hang forever —
        // that was the "stuck in a call, peer unaware" bug).
        final live = _session;
        if (live != null && live.isLive) {
          unawaited(_end(CallEndReason.failed));
        }
      });
    }
  }

  /// Caller: re-gather fresh ICE + re-offer to recover a failed relay path.
  /// The callee answers it through the normal [_onOffer] path. A restart that
  /// itself errors ends the call.
  Future<void> _attemptIceRestart(CallSession s) async {
    try {
      // ignore: avoid_print
      print('NANBCALL ICE failed on ${s.callId} — restart attempt $_iceRestarts');
      // The restart's fresh candidates must not overtake the re-offer, and the
      // peer's candidates for it must wait for its answer.
      _localIce.hold();
      _remoteIce.hold();
      final offer = await _engine!.restartIce();
      if (_session?.callId != s.callId) return;
      _offerSeq++;
      _currentOfferSdp = offer;
      _answerApplied = false;
      if (!await _sendCurrentOffer()) {
        throw StateError('re-offer not sent');
      }
      _armConnectRetry();
    } catch (e) {
      // ignore: avoid_print
      print('NANBCALL ICE restart failed on ${s.callId}: $e');
      await _end(CallEndReason.failed);
    }
  }

  // ── Teardown ──────────────────────────────────────────────────────────────

  bool _matches(CallSignal sig) =>
      _session != null && _session!.isLive && _session!.callId == sig.callId;

  /// Like [_matches] but also matches a from-push placeholder ring — which has
  /// no [CallSession.callId] yet — by conversation, so a `cancel`/`hangup` that
  /// arrives before the real invite reconciled still tears the ring down.
  bool _matchesTeardown(CallSignal sig, String? conversationId) {
    final s = _session;
    if (s == null || !s.isLive) return false;
    if (s.callId == sig.callId) return true;
    return s.awaitingInvite &&
        s.callId.isEmpty &&
        conversationId != null &&
        s.conversationId == conversationId;
  }

  /// Whether [conversationId]'s push ring was declined recently enough that a
  /// just-arrived invite for it should be auto-declined rather than re-rung.
  bool _wasRecentlyDeclined(String conversationId) {
    final at = _pushDeclined[conversationId];
    if (at == null) return false;
    if (_now().difference(at) > const Duration(seconds: 90)) {
      _pushDeclined.remove(conversationId);
      return false;
    }
    return true;
  }

  Future<void> _end(CallEndReason reason) async {
    final s = _session;
    if (s == null || !s.isLive) return;
    _pushRingTimer?.cancel();
    _pushRingTimer = null;
    _outgoingRingTimer?.cancel();
    _outgoingRingTimer = null;
    _iceRecoveryTimer?.cancel();
    _iceRecoveryTimer = null;
    _mediaDropTimer?.cancel();
    _mediaDropTimer = null;
    _connectTimer?.cancel();
    _connectTimer = null;
    _wantAcceptOnInvite = false;
    await _iceSub?.cancel();
    _iceSub = null;
    await _connSub?.cancel();
    _connSub = null;
    _resetNegotiation();
    // Detach the engine BEFORE publishing the ended state (so the UI never
    // binds a renderer we are about to dispose), and CLOSE it after (so a slow
    // or wedged native teardown can't hold the call screen — and the ring tone,
    // which stops on this status edge — open behind it).
    final engine = _engine;
    _engine = null;
    // A ringing-but-never-connected incoming call that ends is a "missed call".
    final effectiveReason = (s.status == CallStatus.incomingRinging &&
            (reason == CallEndReason.cancelled || reason == CallEndReason.hangup))
        ? CallEndReason.missed
        : reason;
    final ended = s.copyWith(
      status: CallStatus.ended,
      endReason: effectiveReason,
    );
    _session = ended;
    notifyListeners();
    try {
      await engine?.close();
    } catch (_) {/* best-effort */}
    _onCallEnded?.call(ended);
  }

  @override
  void dispose() {
    _pushRingTimer?.cancel();
    _outgoingRingTimer?.cancel();
    _iceRecoveryTimer?.cancel();
    _mediaDropTimer?.cancel();
    _connectTimer?.cancel();
    _connectRetryTimer?.cancel();
    _iceSub?.cancel();
    _connSub?.cancel();
    _engine?.close();
    super.dispose();
  }
}
