import 'dart:async';

import 'package:flutter/widgets.dart';

import 'connection_log.dart';
import 'ws_reconnect_supervisor.dart';

/// Bridges Flutter's app-lifecycle events to the supervisor. Excluded from
/// coverage — the supervisor itself has full state-machine tests.
///
/// Wire from the root widget by calling
/// `WidgetsBinding.instance.addObserver(AppLifecycleObserver(supervisor))`
/// in `initState` and `removeObserver(...)` in `dispose`.
///
/// Pass an optional [onResumed] callback to be notified alongside the
/// supervisor (e.g. so [ConversationsNotifier] can replenish KeyPackages on
/// app foreground without subscribing to `WidgetsBinding` directly).
class AppLifecycleObserver extends WidgetsBindingObserver {
  AppLifecycleObserver(
    this._supervisor, {
    this.onResumed,
    this.onPaused,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  /// Resolves the CURRENT supervisor each time, rather than a captured instance.
  /// A Tor SOCKS-port change rebuilds the ws-client/supervisor/notifier
  /// providers, so a once-captured supervisor would go stale (its socket dead)
  /// and resume/reconnect calls would hit a dead instance.
  final WsReconnectSupervisor Function() _supervisor;

  /// Optional callback invoked on every `AppLifecycleState.resumed` event,
  /// after the supervisor's own handler. [stale] is true when the app had been
  /// backgrounded long enough that the transport may have gone dead (radio
  /// sleep / Doze froze the embedded Tor) — the caller uses it to gate an eager
  /// transport reset to real backgrounds, so a quick app-switch stays cheap.
  final void Function(bool stale)? onResumed;

  /// Optional callback invoked when the app leaves the foreground
  /// (`paused` or `hidden`) — e.g. to re-arm the app lock.
  final void Function()? onPaused;

  /// Injectable clock for tests.
  final DateTime Function() _now;

  /// When the app last went to the background. Null while foregrounded.
  DateTime? _backgroundedAt;

  /// A background longer than this likely left the WebSocket half-open (radio
  /// sleep / NAT idle drop), so we force a fresh reconnect on resume instead of
  /// waiting tens of seconds for the next ping timeout to notice — that window
  /// is when "I reopened the app and my message wouldn't send" happens.
  ///
  /// Kept conservative so a quick app-switch (glance at another app, return)
  /// doesn't pay a reconnect — which is several seconds over Tor. A verify-on-
  /// resume probe (see WsClient.probe / WsReconnectSupervisor) supersedes this
  /// blunt time threshold: it keeps a still-live socket regardless of how long
  /// the app was away, reconnecting only when the socket is actually dead.
  static const _staleAfter = Duration(seconds: 30);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    ConnectionLog.instance.add('app ${state.name}');
    if (state == AppLifecycleState.resumed) {
      final bg = _backgroundedAt;
      _backgroundedAt = null;
      final stale = bg != null && _now().difference(bg) >= _staleAfter;
      if (stale) {
        // Long background → the socket MIGHT be stale. Verify it's responsive
        // (cheap probe) and reconnect only if it's actually dead — keeping a
        // live socket avoids a reconnect that costs several seconds over Tor.
        // (Also skips any pending backoff, like onAppResumed.)
        unawaited(_supervisor().verifyConnectionOrReconnect());
      } else {
        _supervisor().onAppResumed();
      }
      onResumed?.call(stale);
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _backgroundedAt ??= _now();
      onPaused?.call();
    }
  }
}
