import '../../core/crypto/crypto_bridge.dart';
import '../../core/models/jwt_session.dart';
import '../../core/network/api_client.dart';
import 'session_repository.dart';

/// Manages session refresh + sign-out. First-time-create flow lives in
/// `OnboardingNotifier`; this notifier is for returning users.
class LoginNotifier {
  LoginNotifier({
    required ApiClient apiClient,
    required CryptoBridge crypto,
    required SessionRepository sessions,
  })  : _api = apiClient,
        _crypto = crypto,
        _sessions = sessions;

  final ApiClient _api;
  final CryptoBridge _crypto;
  final SessionRepository _sessions;

  /// Returns the refreshed session, or null if no session was stored to begin
  /// with (caller routes the user to onboarding).
  ///
  /// Throws [StateError] if a session is stored but no identity exists in the
  /// crypto bridge (corrupt local state — caller should sign the user out and
  /// route to onboarding).
  Future<JwtSession?> refreshSession() async {
    final stored = await _sessions.current();
    if (stored == null) return null;

    // The username MUST be the real one: IssueChallenge looks the account up
    // by username BEFORE touching the device id, so an empty username 404s.
    // (An old comment here claimed the server keys off device_id — wrong, and
    // because refreshes only happen once a JWT ages past 24h, the bug stayed
    // invisible until the first overnight session.)
    final reply = await _api.requestChallenge(
      username: stored.username,
      deviceId: stored.deviceId,
    );

    final identity = await _crypto.currentIdentity();
    if (identity == null) {
      throw StateError('login: stored session but no identity on this device');
    }
    final signature = await _crypto.signWithIdentity(identity, reply.challenge);

    final fresh = await _api.submitSession(
      // Must match the challenge request — the server keys the issued
      // challenge under "username|deviceId".
      username: stored.username,
      deviceId: stored.deviceId,
      challenge: reply.challenge,
      signature: signature,
    );
    final updated = JwtSession(
      accountId: stored.accountId,
      deviceId: stored.deviceId,
      jwt: fresh.jwt,
      username: stored.username,
    );
    await _sessions.save(updated);

    // Apply the refreshed JWT to the shared REST client. The WS supervisor
    // drives this refresh on a rejected/expired token; without this line the
    // socket reconnects with the new token while authed REST calls (e.g.
    // lookupAccount) keep sending the stale one and 401. Same shared ApiClient
    // instance as connect()'s setBearerToken — see apiClientProvider.
    _api.setBearerToken(updated.jwt);

    // Open the CoreCrypto store now that a valid session is confirmed.
    // The identity seed was already on disk; mlsInit opens the store.
    // BEST-EFFORT: a store that won't open must not cost the user their
    // refreshed session — that would sign them out of a working account over
    // MLS state the boot path and the replenisher both retry anyway.
    try {
      await _crypto.mlsInit();
    } catch (e) {
      // ignore: avoid_print
      print('login: MLS store init failed: $e — continuing without MLS');
    }

    return updated;
  }

  Future<void> signOut() async {
    await _sessions.clear();
  }
}
