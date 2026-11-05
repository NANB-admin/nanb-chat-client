import '../models/api_error.dart';

/// Retries an operation while it fails **transiently** — an [ApiError] carrying
/// no `statusCode`, meaning the request never reached the server at all.
///
/// The motivating case is the built-in-Tor window. Until Arti binds its SOCKS
/// port, `socksProxyProvider` routes through a fail-closed sentinel and every
/// request is refused; and at the moment Tor *does* connect, the changed port
/// rebuilds the API client, which then has no bearer for a beat (see
/// `ApiClientDio._authHeaders`). Both are fail-closed by design — the transport
/// must never leak to clearnet — so a caller's job is to SURVIVE the gap, not to
/// bypass it. Without that, one send fired into the window is lost for good.
///
/// A failure that DOES carry a status code is a real answer from the server: the
/// request arrived and was rejected on its merits (410 gone, 413 too large, …).
/// Retrying it would only repeat the rejection, so it rethrows at once.
///
/// This is deliberately shared: media survived the Tor window for a long time
/// while text sends did not, purely because only one of the two paths had this
/// policy. One copy, one behaviour.
class TransientRetry {
  TransientRetry({
    int maxRetries = 10,
    Future<void> Function(Duration)? delay,
  })  : _maxRetries = maxRetries,
        _delay = delay ?? Future<void>.delayed;

  /// With [_backoffFor]'s curve the default budget waits ~19s in total — enough
  /// to cover a typical Tor bootstrap, after which a genuinely offline caller
  /// fails rather than hanging forever.
  final int _maxRetries;

  /// Injectable so tests don't sleep through the backoff.
  final Future<void> Function(Duration) _delay;

  /// Runs [op], retrying while it throws a transient [ApiError].
  Future<T> run<T>(Future<T> Function() op) async {
    var attempt = 0;
    while (true) {
      try {
        return await op();
      } on ApiError catch (e) {
        final transient = e.statusCode == null;
        if (!transient || attempt >= _maxRetries) rethrow;
        attempt++;
        await _delay(_backoffFor(attempt));
      }
    }
  }

  /// 250ms doubling per attempt, capped at 2.5s.
  static Duration _backoffFor(int attempt) {
    final shift = (attempt - 1) > 4 ? 4 : (attempt - 1);
    final ms = 250 << shift; // 250, 500, 1000, 2000, 4000
    return Duration(milliseconds: ms > 2500 ? 2500 : ms);
  }
}
