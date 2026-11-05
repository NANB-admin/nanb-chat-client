import 'dart:async';

import '../network/api_client.dart';
import 'push_token_provider.dart';

/// Coordinates push-token registration. [bootstrap] runs on every `connect()`
/// — cheap, idempotent (the server upserts by device), and the ONLY thing
/// standing between this device and silence: with no token registered the
/// server cannot push at all, and nothing else would ever notice. Re-POSTing
/// each connect is what repairs a registration that failed while offline, or a
/// server-side row that went missing.
///
/// Also listens to [PushTokenProvider.onTokenRefresh] so a rotated token
/// re-registers immediately rather than waiting for the next connect.
class PushTokenRegistrar {
  PushTokenRegistrar({
    required ApiClient api,
    required PushTokenProvider provider,
  })  : _api = api,
        _provider = provider;

  final ApiClient _api;
  final PushTokenProvider _provider;
  StreamSubscription<String>? _sub;

  /// Whether the last registration attempt reached the server. Null before the
  /// first attempt, or when the platform has no token to register (FCM off).
  /// Surfaced in Settings → Notifications: a device that never registered gets
  /// NO pushes, and that is otherwise completely invisible to the user.
  bool? get lastRegistrationSucceeded => _lastOk;
  bool? _lastOk;

  /// Whether the last [bootstrap] found NO token to register at all — the
  /// platform never handed one over. That is a DIFFERENT failure from a POST
  /// that didn't reach the server: there is nothing to send, so reconnecting
  /// won't fix it; the user has to look at their notification permission (or
  /// the push opt-in). It used to be completely silent — [lastRegistrationSucceeded]
  /// stayed null, so Settings rendered nothing at all and a device that could
  /// never be woken looked exactly like a healthy one.
  bool get lastFoundNoToken => _noToken;
  bool _noToken = false;

  Future<void> bootstrap() async {
    final initial = await _provider.currentToken();
    if (initial != null && initial.isNotEmpty) {
      _noToken = false;
      await _post(initial);
    } else {
      _noToken = true;
    }
    // bootstrap() runs per connect, so REPLACE the previous subscription rather
    // than stacking another listener on top of it — otherwise every reconnect
    // added one more, and a single token rotation fired one POST per reconnect
    // the app had ever made.
    await _sub?.cancel();
    _sub = _provider.onTokenRefresh.listen(_post);
  }

  Future<void> _post(String token) async {
    try {
      await _api.registerPushToken(platform: _provider.platform, token: token);
      _lastOk = true;
    } catch (_) {
      // Best-effort: the next connect re-POSTs, and the foreground catchup
      // picks up the messages regardless. Recorded so the user can SEE that
      // this device isn't currently reachable by push.
      _lastOk = false;
    }
  }

  Future<void> dispose() async {
    await _sub?.cancel();
    _sub = null;
  }
}
