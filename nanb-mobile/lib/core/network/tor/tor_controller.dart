import 'dart:async';

import 'package:flutter/foundation.dart';

import 'tor_engine.dart';
import 'tor_status.dart';

/// Owns the embedded-Tor lifecycle + current status, decoupled from the native
/// engine (injected [TorEngine]) so it's fully unit-testable. The networking
/// layer reads [socksPort] once [isConnected] to route through Tor.
///
/// **Fail-closed (design §8):** while Tor is the selected transport, callers
/// must NOT fall back to clearnet unless [status] is [TorPhase.off]. A
/// bootstrapping/error state means "hold", not "connect directly".
class TorController extends ChangeNotifier {
  TorController(this._engine);

  final TorEngine _engine;
  StreamSubscription<TorStatus>? _sub;
  TorStatus _status = const TorStatus.off();

  TorStatus get status => _status;
  bool get isConnected => _status.isConnected;
  TorPhase get phase => _status.phase;

  /// The live SOCKS5 port, or null until [TorPhase.connected].
  int? get socksPort => _status.socksPort;

  /// Start (idempotently) and begin bootstrapping. No-op if already
  /// starting/bootstrapping/connected. Engine status updates drive [status]
  /// from here on; a start failure lands in [TorPhase.error].
  Future<void> start() async {
    switch (_status.phase) {
      case TorPhase.starting:
      case TorPhase.bootstrapping:
      case TorPhase.connected:
        return; // already up or coming up
      case TorPhase.off:
      case TorPhase.error:
        break; // (re)start
    }
    _sub ??= _engine.status.listen(
      _apply,
      onError: (Object e) =>
          _apply(TorStatus(phase: TorPhase.error, message: '$e')),
    );
    _apply(const TorStatus.starting());
    try {
      await _engine.start();
    } catch (e) {
      _apply(TorStatus(phase: TorPhase.error, message: '$e'));
    }
  }

  /// Re-establish Tor after an OS suspend/resume tore down its circuits (iOS
  /// suspends the app in the background). While `connected`, [start] is a no-op
  /// and `socksProxyProvider` keeps handing out the now-dead SOCKS port, so the
  /// socket retries through a dead proxy forever ("Reconnecting via Tor…"). This
  /// holds the network (bootstrapping → fail-closed sentinel) and asks the engine
  /// to reset in place; the native side rebuilds Tor's circuits and re-emits the
  /// real status + live port, which reroutes the HTTP/WS clients onto the
  /// recovered Tor. No-op when Tor isn't the active transport ([TorPhase.off]).
  Future<void> reconnectAfterResume() async {
    // Skip when Tor isn't the active transport (off), or a connection attempt is
    // already in progress (starting/bootstrapping): a fresh start/reconnect is
    // mid-flight, so restarting it would only churn — on iOS that means
    // needlessly re-bootstrapping Arti (it was triggering 3-4 restarts on open).
    switch (_status.phase) {
      case TorPhase.off:
      case TorPhase.starting:
      case TorPhase.bootstrapping:
        return;
      case TorPhase.connected:
      case TorPhase.error:
        break;
    }
    // Full restart — NOT a cheap wake. This hook fires only when the resume
    // liveness probe couldn't confirm the socket, which after a real suspend
    // means a WEDGED Arti: its circuits died while its SOCKS listener stayed
    // bound (so `isConnected` lies). A wake does NOT heal that — verified
    // on-device (Pixel/Nokia forced-Doze, 2026-07-21): the WS redial through the
    // wedged client just HANGS (no failure is registered, so it never even
    // escalates), leaving the app stuck on "Connecting via Tor…" indefinitely.
    // Only a fresh bootstrap recovers. (Dormant-on-pause + wake-on-foreground
    // still help the light case where the socket survives a short background and
    // this hook never fires.)
    await _resetEngine();
  }

  /// Wake Arti from the dormant state [prepareForBackground] put it in, on app
  /// resume. Cheap in-place recovery: the client + SOCKS port survived, so this
  /// resumes circuit upkeep WITHOUT a re-bootstrap and WITHOUT changing [status]
  /// (the port is unchanged, so no `socksProxyProvider`/client rebuild). Traffic
  /// keeps flowing through the same warm Tor — Arti also auto-wakes on first use.
  /// Best-effort: a failure just leaves the supervisor's reconnect / repeated-
  /// failure recovery to handle it. No-op when Tor isn't the active transport.
  Future<void> wakeFromBackground() async {
    if (_status.phase == TorPhase.off) return;
    try {
      await _engine.wake();
    } catch (_) {
      // best-effort; the supervisor still drives socket recovery.
    }
  }

  /// Force a full engine reset when the transport is provably broken even
  /// though Arti still reports `connected` — e.g. the WebSocket can't connect
  /// after repeated tries: Arti's SOCKS listener is still bound (so [isConnected]
  /// keeps lying) but its circuits died (a post-doze/sleep wedge), and a plain
  /// status re-poll can never heal that. Only a fresh bootstrap can. The reset
  /// re-emits a live SOCKS port, which reroutes the HTTP/WS clients onto the
  /// recovered Tor. No-op when Tor isn't the active transport ([TorPhase.off])
  /// or a connect attempt is already mid-flight (a reset would only churn it).
  Future<void> forceRestart() async {
    switch (_status.phase) {
      case TorPhase.off:
      case TorPhase.starting:
      case TorPhase.bootstrapping:
        return;
      case TorPhase.connected:
      case TorPhase.error:
        break;
    }
    await _resetEngine();
  }

  /// Hold the network (bootstrapping → fail-closed sentinel) and ask the engine
  /// to reset in place; the native side rebuilds Tor's circuits and re-emits the
  /// real status + live port. Shared by [reconnectAfterResume] and [forceRestart].
  Future<void> _resetEngine() async {
    _sub ??= _engine.status.listen(
      _apply,
      onError: (Object e) =>
          _apply(TorStatus(phase: TorPhase.error, message: '$e')),
    );
    _apply(const TorStatus(phase: TorPhase.bootstrapping));
    try {
      await _engine.reconnect();
    } catch (e) {
      _apply(TorStatus(phase: TorPhase.error, message: '$e'));
    }
  }

  /// Called from `app.dart` onPaused when Tor is the transport: asks the engine
  /// to idle Tor's network before the OS suspends the app, so the resume path has
  /// a better chance of recovering it in place rather than finding it wedged (see
  /// [TorEngine.prepareForBackground]). Only meaningful while connected;
  /// best-effort and never changes [status].
  Future<void> prepareForBackground() async {
    if (_status.phase != TorPhase.connected) return;
    try {
      await _engine.prepareForBackground();
    } catch (_) {
      // best-effort; the resume path still attempts recovery.
    }
  }

  /// Stop the engine and return to [TorPhase.off]. Best-effort: even if the
  /// engine throws on stop, the controller lands in `off`.
  Future<void> stop() async {
    try {
      await _engine.stop();
    } catch (_) {
      // best-effort teardown
    } finally {
      _apply(const TorStatus.off());
    }
  }

  void _apply(TorStatus next) {
    if (next == _status) return;
    _status = next;
    notifyListeners();
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    _sub = null;
    super.dispose();
  }
}
