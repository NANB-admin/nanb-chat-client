import 'models/call_session.dart';
import 'models/call_signal.dart';

/// Whether an ended call is evidence that the CACHED TURN credential may be
/// bad, so the next call should refetch instead of reusing it.
///
/// [TurnCredentialsCache] serves one credential for up to ~11h. If it stops
/// working before then (coturn's shared secret rotated, the relay rebuilt, a
/// clock-skewed expiry) every call in that window fails to allocate a relay —
/// relay-only means no fallback — and re-dialling cannot help, because the
/// re-dial reads the same cache. A call that failed WITHOUT ever reaching media
/// is the only signal we get, so it drops the cache; the cost when the
/// credential was actually fine is one extra fetch on the next call.
bool shouldDropTurnCredentials(CallSession ended) =>
    ended.endReason == CallEndReason.failed && ended.connectedAt == null;
