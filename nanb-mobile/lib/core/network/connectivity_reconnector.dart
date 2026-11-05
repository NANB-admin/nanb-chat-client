import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';

import 'connection_log.dart';

/// Forces a fresh WebSocket reconnect when the device's network changes —
/// regaining connectivity after a dead zone, or a WiFi<->cellular handoff.
///
/// Why: [WsReconnectSupervisor]'s backoff loop recovers *eventually*, but a
/// network change frequently leaves the previous socket half-open (still bound
/// to an interface that's gone). `WsClient.isConnected` then keeps reporting
/// "connected" until the next server ping times out (tens of seconds), and
/// sends silently fail in that window — the "I got signal back but my message
/// wouldn't send" case. Kicking `forceReconnect()` on the connectivity edge
/// collapses that window.
///
/// Decoupled from connectivity_plus for testability: it consumes a stream of
/// opaque network *signatures* (a stable string per network identity; the
/// sentinel [kOffline] means no connectivity). [networkSignature] maps the
/// plugin's results to that string at the wiring site, so the reconnect logic
/// can be unit-tested with plain strings and no platform channels.
class ConnectivityReconnector {
  ConnectivityReconnector({
    required Stream<String> networkChanges,
    required void Function() onNetworkRegained,
  })  : _networkChanges = networkChanges,
        _onNetworkRegained = onNetworkRegained;

  final Stream<String> _networkChanges;
  final void Function() _onNetworkRegained;

  StreamSubscription<String>? _sub;
  String? _last;

  /// The offline signature. Distinct from any real network's signature.
  static const String kOffline = 'none';

  void start() {
    _sub ??= _networkChanges.listen(_onSignature);
  }

  void _onSignature(String signature) {
    final prev = _last;
    _last = signature;
    ConnectionLog.instance.add('network $prev -> $signature');
    // Offline: nothing to reconnect to. The supervisor notices the drop (or its
    // next ping does); we just remember we're offline so the *return* to a
    // network reads as a change and fires below.
    if (signature == kOffline) return;
    // First reading seeds the baseline. Startup connect (ChatListScreen) owns
    // the initial connection, so don't also kick one here.
    if (prev == null) return;
    // Online now, on a different network than before (offline->online, or a
    // WiFi<->cellular handoff): the previous socket may be stranded. Reconnect.
    // `forceReconnect` no-ops when the supervisor isn't started (signed out /
    // not on the chat list) or is already connecting.
    if (signature != prev) {
      _onNetworkRegained();
    }
  }

  Future<void> dispose() async {
    await _sub?.cancel();
    _sub = null;
  }
}

/// Maps connectivity_plus results to a stable, order-independent signature.
/// Returns [ConnectivityReconnector.kOffline] when there is no real network.
/// Pure — safe to call without platform channels.
String networkSignature(List<ConnectivityResult> results) {
  final real = results
      .where((r) => r != ConnectivityResult.none)
      .map((r) => r.name)
      .toList()
    ..sort();
  return real.isEmpty ? ConnectivityReconnector.kOffline : real.join('+');
}

/// Emits the current network signature immediately, then every subsequent
/// change. `Connectivity.onConnectivityChanged` does NOT replay the current
/// value on listen, so without this seed the *first* network change after
/// launch would be mistaken for the baseline and skipped.
Stream<String> networkSignatureStream(Connectivity connectivity) async* {
  try {
    yield networkSignature(await connectivity.checkConnectivity());
  } catch (_) {
    // Initial probe can fail on some platforms; the change stream still flows.
  }
  yield* connectivity.onConnectivityChanged.map(networkSignature);
}
