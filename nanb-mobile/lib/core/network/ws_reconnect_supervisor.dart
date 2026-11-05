import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../models/api_error.dart';
import '../models/jwt_session.dart';
import 'connection_log.dart';
import 'connection_state.dart';
import 'jwt_expiry.dart';
import 'ws_client.dart';
import 'ws_connection_event.dart';

/// Owns the WS reconnect state machine. See
/// `docs/superpowers/specs/2026-05-15-flutter-ws-reconnect-design.md`
/// for the full design.
///
/// Layers added across the implementation plan:
///   - Task 3: bare happy path (start -> connecting -> connected)
///   - Task 4: ws.connect() failure -> backoff -> retry loop
///   - Task 5: counter reset on connect + WS onDone -> reconnecting
///   - Task 6: JWT expiry gating + refresh-on-stale
///   - Task 7: refresh failure -> signedOut
///   - Task 8: onAppResumed transitions
///   - Task 9: stop / restart / single-flight
class WsReconnectSupervisor extends ChangeNotifier {
  WsReconnectSupervisor({
    required WsClient wsClient,
    required Future<JwtSession?> Function() sessionLoader,
    required Future<JwtSession?> Function() refreshSession,
    Random? random,
    Future<void> Function(Duration)? delay,
    Future<void> Function()? onRepeatedFailure,
    Future<void> Function()? onResumeTransportUnconfirmed,
    int repeatedFailureThreshold = 3,
  })  : _ws = wsClient,
        _loadSession = sessionLoader,
        _refresh = refreshSession,
        _random = random ?? Random.secure(),
        _delay = delay ?? Future<void>.delayed,
        _onRepeatedFailure = onRepeatedFailure,
        _onResumeTransportUnconfirmed = onResumeTransportUnconfirmed,
        _repeatedFailureThreshold = repeatedFailureThreshold;

  final WsClient _ws;
  final Future<JwtSession?> Function() _loadSession;
  final Future<JwtSession?> Function() _refresh;
  final Random _random;
  final Future<void> Function(Duration) _delay;

  /// Invoked when reconnect attempts keep failing — a hook to recover a stale
  /// transport underneath the socket (e.g. a wedged embedded Tor whose SOCKS
  /// listener is up but whose circuits are dead). Fires once the consecutive
  /// failure count reaches [_repeatedFailureThreshold], then again every
  /// [_repeatedFailureThreshold] further failures (a transport reset is heavy,
  /// so we don't do it every attempt). Reset to silent on the next success.
  final Future<void> Function()? _onRepeatedFailure;

  /// Invoked from [verifyConnectionOrReconnect] (app-resume) when the socket's
  /// liveness could NOT be confirmed — the probe got no pong, or we resumed
  /// mid-reconnect. A hook to recover the transport beneath the socket (restart
  /// a wedged embedded Tor) ONLY when it's actually needed: a resume where the
  /// socket is still alive never fires this, so it doesn't pay a Tor
  /// re-bootstrap (several seconds) on every foreground.
  final Future<void> Function()? _onResumeTransportUnconfirmed;
  final int _repeatedFailureThreshold;

  ConnectionState _state = ConnectionState.connecting;
  ConnectionState get state => _state;

  final StreamController<WsConnectionEvent> _events =
      StreamController<WsConnectionEvent>.broadcast();
  Stream<WsConnectionEvent> get events => _events.stream;

  bool _started = false;
  int _attemptCounter = 0;
  StreamSubscription<void>? _disconnectSub;
  Completer<void>? _backoffWaiter;

  Future<void> start() async {
    if (_started) return;
    _started = true;
    _attemptCounter = 0;
    await _runReconnectLoop();
  }

  Future<void> stop() async {
    _started = false;
    await _disconnectSub?.cancel();
    _disconnectSub = null;
  }

  /// Hook called by `AppLifecycleObserver` when the app returns to the
  /// foreground. If we're waiting on a backoff timer, cancel it and try
  /// to reconnect right away. Otherwise no-op.
  void onAppResumed() {
    if (!_started) return;
    switch (_state) {
      case ConnectionState.reconnecting:
        _backoffWaiter?.complete();
        _backoffWaiter = null;
      case ConnectionState.connecting:
      case ConnectionState.connected:
      case ConnectionState.signedOut:
        break;
    }
  }

  /// Forces a fresh reconnect when the socket is likely stale even though the
  /// supervisor still believes it's `connected` — e.g. after a long background
  /// (the radio slept / NAT dropped the idle connection) or a network change.
  /// A genuine half-open socket is otherwise only noticed by the next ping
  /// timeout (tens of seconds), during which `isConnected` lies and sends
  /// silently fail. When already `reconnecting`, this just skips the backoff.
  void forceReconnect({String source = 'unknown'}) {
    if (!_started) return;
    ConnectionLog.instance
        .add('forceReconnect source=$source state=${_state.name}');
    switch (_state) {
      case ConnectionState.reconnecting:
        _backoffWaiter?.complete();
        _backoffWaiter = null;
      case ConnectionState.connected:
        // Possibly half-open: drop it and reconnect from scratch. AWAIT the
        // disconnect before looping — `connect()` is idempotent on a non-null
        // channel, so reconnecting before `disconnect()` nulls it would no-op
        // onto the dead socket. The deliberate disconnect() doesn't emit on
        // `disconnects` (it cancels the read sub first), so it won't also fire
        // `_onWsClosed`; we drive the loop ourselves, as `_onWsClosed` does.
        _transitionTo(ConnectionState.reconnecting);
        unawaited(_ws.disconnect().whenComplete(() {
          if (_started) scheduleMicrotask(_runReconnectLoop);
        }));
      case ConnectionState.connecting:
      case ConnectionState.signedOut:
        break;
    }
  }

  /// App-resume path: when the socket MIGHT be stale (we were backgrounded a
  /// while), VERIFY it's actually responsive with a cheap liveness probe before
  /// paying for a full reconnect — which is several seconds over Tor. A live
  /// socket is kept (no user-visible reconnect); only a genuinely dead one is
  /// dropped + reconnected. Supersedes a blunt time-based [forceReconnect] on
  /// resume. When not `connected`, behaves like [onAppResumed].
  Future<void> verifyConnectionOrReconnect() async {
    if (!_started) return;
    switch (_state) {
      case ConnectionState.connected:
        final alive = await _ws.probe();
        // ignore: avoid_print
        print('NANBNET resume verify: socket alive=$alive '
            '(${alive ? "kept — no reconnect" : "dead — reconnecting"})');
        // Re-check after the await: a real disconnect may have landed meanwhile
        // (it drives its own reconnect), so only force one if still connected.
        if (!alive && _started && _state == ConnectionState.connected) {
          // The transport didn't answer. Recover the layer beneath the socket
          // first (e.g. restart a wedged Tor whose SOCKS port survived the
          // suspend but whose circuits died) — a plain WS reconnect would just
          // keep failing through it. A live socket is left untouched above, so
          // we never pay a Tor re-bootstrap on a resume the connection survived.
          unawaited(_onResumeTransportUnconfirmed?.call());
          forceReconnect(source: 'resume-probe-failed');
        }
      case ConnectionState.reconnecting:
        // Already looping on reconnects; if they're failing through a wedged
        // transport, recover it too, then drop the backoff to retry now.
        unawaited(_onResumeTransportUnconfirmed?.call());
        _backoffWaiter?.complete();
        _backoffWaiter = null;
      case ConnectionState.connecting:
        // Eager: an attempt is in flight but may be grinding through a wedged
        // transport (no live socket to probe yet). Recover the transport now
        // rather than waiting for this attempt to time out and the repeated-
        // failure escalation to eventually kick in.
        unawaited(_onResumeTransportUnconfirmed?.call());
      case ConnectionState.signedOut:
        break;
    }
  }

  /// Drives attempts until `_started` flips false. After a failed attempt
  /// the supervisor enters `reconnecting`, sleeps for the backoff window,
  /// then tries again. After a successful attempt the loop exits and the
  /// supervisor stays in `connected` until something external (Task 5)
  /// signals a drop.
  Future<void> _runReconnectLoop() async {
    while (_started) {
      try {
        await _attemptOnce();
        if (_state == ConnectionState.signedOut) return;
        if (_state == ConnectionState.connected) return;
      } catch (e) {
        debugPrint('ws-supervisor: attempt failed: $e');
        if (!_started) return;
        _transitionTo(ConnectionState.reconnecting);
        await _waitWithCancel(_backoffDelay(_attemptCounter));
        _attemptCounter++;
        if (!_started) return;
        _maybeRecoverTransport();
      }
    }
  }

  Future<void> _attemptOnce() async {
    _transitionTo(ConnectionState.connecting);
    var session = await _loadSession();
    if (session == null) throw StateError('no session available');

    final exp = jwtExpiry(session.jwt);
    final threshold = DateTime.now().toUtc().add(const Duration(seconds: 60));
    if (exp == null || exp.isBefore(threshold)) {
      try {
        final fresh = await _refresh();
        if (fresh == null) throw StateError('refresh returned null');
        session = fresh;
      } on StateError {
        // No stored session / no identity on this device — nothing a retry
        // can recover.
        _signOut();
        return;
      } on ApiError catch (e) {
        // Sign out ONLY when the server definitively rejected this device's
        // identity. Anything else (network blip, 5xx, server briefly down at
        // the 24h token boundary) must retry with backoff — signedOut
        // triggers clearLocalData() downstream, and wiping an E2EE device
        // over a transient failure destroys unrecoverable history.
        const definitive = {
          'account_not_found',
          'device_not_found',
          'bad_signature',
          'unauthorized',
        };
        if (definitive.contains(e.code)) {
          _signOut();
          return;
        }
        rethrow; // -> reconnecting + backoff retry
      }
    }

    try {
      await _ws.connect(session.jwt);
    } catch (_) {
      // A rejected WS handshake can mean this device was revoked server-side
      // (e.g. a recovery-phrase takeover on another phone): the JWT is still
      // signature-valid, so the near-expiry refresh above didn't fire. Probe
      // with a refresh — the same definitive-rejection logic signs out + wipes
      // ONLY when the server says this device is gone; a transient/network
      // failure leaves the device untouched and we rethrow to back off. Skip
      // when we already refreshed above (token was near expiry).
      if (exp != null && !exp.isBefore(threshold)) {
        if (await _signOutIfRevoked()) return;
      }
      rethrow;
    }
    _transitionTo(ConnectionState.connected);
    _attemptCounter = 0; // reset on success
    _events.add(const Reconnected());
    // Drop detection: the client emits on `disconnects` when an established
    // connection dies underneath it. (The `envelopes` broadcast stream never
    // closes — listening for its onDone, as this used to, detects nothing:
    // the supervisor then believes it's connected forever and real-time
    // delivery silently degrades to catchup-only.)
    await _disconnectSub?.cancel();
    _disconnectSub = _ws.disconnects.listen((_) => _onWsClosed());
  }

  void _signOut() {
    _started = false;
    _transitionTo(ConnectionState.signedOut);
    _events.add(const SignedOut());
  }

  /// Leaves the TERMINAL [ConnectionState.signedOut] state because a brand-new
  /// session now exists (account created, restored, or this device linked).
  ///
  /// Every other transition treats `signedOut` as final — correctly, since it
  /// means the server rejected THIS device and no amount of retrying will help.
  /// But onboarding replaces the credentials outright, so the verdict no longer
  /// applies, and without this the state is unrecoverable in-process: the
  /// router keeps forcing /welcome, which prevents `ChatListScreen` from ever
  /// mounting — and mounting it is what calls `connect()`, the only thing that
  /// would clear the state. The user had to kill and relaunch the app after
  /// creating an account.
  ///
  /// Moves to `connecting`, not `connected`: no socket exists yet. The caller
  /// (`connect()`, via the chat list) establishes one.
  void clearSignedOut() {
    if (_state != ConnectionState.signedOut) return;
    _transitionTo(ConnectionState.connecting);
  }

  /// Probes the server with a token refresh to tell a server-side revocation
  /// (e.g. a recovery-phrase takeover) apart from a transient WS handshake
  /// failure. Signs out + wipes ONLY on a definitive rejection — never on a
  /// network/5xx error. Returns true when it signed out (caller should stop),
  /// false otherwise (caller retries via backoff).
  Future<bool> _signOutIfRevoked() async {
    try {
      await _refresh();
      return false; // refresh worked → token was fine; the WS failure was transient.
    } on ApiError catch (e) {
      const definitive = {
        'account_not_found',
        'device_not_found',
        'bad_signature',
        'unauthorized',
      };
      if (definitive.contains(e.code)) {
        _signOut();
        return true;
      }
      return false;
    } catch (_) {
      return false; // StateError / network — transient; retry via backoff.
    }
  }

  /// After enough consecutive failed attempts, ask the transport-recovery hook
  /// to reset the layer beneath the socket (the wedged-Tor case). Fires at the
  /// threshold and then once per further threshold of failures, never every
  /// attempt. The counter resets to 0 on a successful connect, so a transport
  /// that recovers stops triggering resets. Fire-and-forget: a reset reroutes
  /// the clients (rebuilding this supervisor), so we don't await it here.
  void _maybeRecoverTransport() {
    final cb = _onRepeatedFailure;
    if (cb == null) return;
    if (_attemptCounter < _repeatedFailureThreshold) return;
    if (_attemptCounter % _repeatedFailureThreshold != 0) return;
    unawaited(cb());
  }

  void _onWsClosed() {
    if (!_started) return;
    if (_state != ConnectionState.connected) return;
    _transitionTo(ConnectionState.reconnecting);
    scheduleMicrotask(_runReconnectLoop);
  }

  /// Exponential backoff: 1, 2, 4, 8, 16, 30 (capped) seconds, with
  /// ±25% multiplicative jitter. `n` is the zero-based attempt index
  /// (0 = first retry).
  Duration _backoffDelay(int n) {
    final raw = 1 << min(n, 5); // 1, 2, 4, 8, 16, 32 (for n>=5)
    final cappedBase = raw > 30 ? 30 : raw;
    final jitter = 0.75 + _random.nextDouble() * 0.5; // [0.75, 1.25)
    final ms = (cappedBase * 1000 * jitter).round();
    return Duration(milliseconds: ms);
  }

  /// Awaits the delay OR an external cancel via `onAppResumed`. Whichever
  /// completes first ends the wait.
  Future<void> _waitWithCancel(Duration d) async {
    final waiter = Completer<void>();
    _backoffWaiter = waiter;
    unawaited(_delay(d).then((_) {
      if (!waiter.isCompleted) waiter.complete();
    }));
    await waiter.future;
    _backoffWaiter = null;
  }

  void _transitionTo(ConnectionState next) {
    if (_state == next) return;
    ConnectionLog.instance.add('state ${_state.name} -> ${next.name}');
    _state = next;
    notifyListeners();
  }

  @override
  void dispose() {
    _events.close();
    super.dispose();
  }
}
