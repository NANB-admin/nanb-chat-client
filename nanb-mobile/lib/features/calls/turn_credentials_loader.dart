import '../../core/models/turn_credentials.dart';
import 'models/call_ice_config.dart';

/// Loads the call ICE config (TURN relay credentials) with a small retry.
///
/// The credentials fetch rides the same — possibly cold — Tor path as the rest
/// of the app, so a single transient failure otherwise dooms the whole call to a
/// relay-only config with no servers, which can never connect (it just hangs in
/// "Connecting…"). Retrying briefly recovers a flaky fetch; if every attempt
/// fails this THROWS so the caller fails the call FAST with a clear error
/// instead of hanging.
Future<CallIceConfig> loadCallIceConfig(
  Future<TurnCredentials> Function() fetch, {
  int attempts = 3,
  Duration Function(int attempt) backoff = _defaultBackoff,
}) async {
  assert(attempts >= 1);
  Object? lastError;
  for (var attempt = 0; attempt < attempts; attempt++) {
    try {
      final c = await fetch();
      return CallIceConfig(
        iceServers: [
          {'urls': c.urls, 'username': c.username, 'credential': c.credential},
        ],
      );
    } catch (e) {
      lastError = e;
      if (attempt < attempts - 1) await Future<void>.delayed(backoff(attempt));
    }
  }
  throw StateError(
      'turn: credentials unavailable after $attempts attempts: $lastError');
}

/// Linear backoff: 400ms, 800ms, 1200ms, … — short enough to keep call setup
/// snappy, long enough to ride out a brief Tor/network hiccup.
Duration _defaultBackoff(int attempt) =>
    Duration(milliseconds: 400 * (attempt + 1));
