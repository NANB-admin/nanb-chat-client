import '../../core/models/jwt_session.dart';
import '../../core/secure_storage/secure_storage.dart';

/// Persists the active JWT session in secure storage. Anything that needs the
/// current session (router redirect, ApiClient bearer token) reads through here.
class SessionRepository {
  SessionRepository(this._storage);

  final SecureStorage _storage;

  /// In-memory mirror of the persisted session. Populated by [current] (first
  /// load) and [save]; dropped by [clear]. Lets hot readers — the router
  /// redirect, the ApiClient bearer, the settings identity card — get the
  /// session without re-hitting secure storage (four keystore reads that, on
  /// some Android devices, add up to a visible delay). [save] is the only
  /// writer of the JWT (login + refreshSession both route through it), so the
  /// mirror can never serve a stale token.
  JwtSession? _cached;

  static const _kAccountId = 'session.account_id';
  static const _kDeviceId = 'session.device_id';
  static const _kJwt = 'session.jwt';
  static const _kUsername = 'session.username';
  static const _kExists = 'session.exists';
  static const _kSignedOut = 'session.signed_out';

  Future<JwtSession?> current() async {
    if (_cached != null) return _cached;
    // Parallel reads: these four keys are independent, so awaiting them in
    // sequence needlessly serialises four keystore round-trips.
    final values = await Future.wait([
      _storage.getString(_kAccountId),
      _storage.getString(_kDeviceId),
      _storage.getString(_kJwt),
      _storage.getString(_kUsername),
    ]);
    final accountId = values[0];
    final deviceId = values[1];
    final jwt = values[2];
    final username = values[3];
    if (accountId == null || deviceId == null || jwt == null || username == null) return null;
    return _cached = JwtSession(
        accountId: accountId, deviceId: deviceId, jwt: jwt, username: username);
  }

  Future<void> save(JwtSession session) async {
    _cached = session;
    await _storage.putString(_kAccountId, session.accountId);
    await _storage.putString(_kDeviceId, session.deviceId);
    await _storage.putString(_kJwt, session.jwt);
    await _storage.putString(_kUsername, session.username);
    await _storage.putString(_kExists, '1');
    // A fresh login/restore clears any lingering signed-out gate — the
    // returning session is, by definition, signed in.
    await _storage.delete(_kSignedOut);
  }

  Future<void> clear() async {
    _cached = null;
    await _storage.delete(_kAccountId);
    await _storage.delete(_kDeviceId);
    await _storage.delete(_kJwt);
    await _storage.delete(_kUsername);
    await _storage.delete(_kExists);
    await _storage.delete(_kSignedOut);
  }

  /// Fast boolean: is a session persisted on this device? One key read, no
  /// JSON assembly — used at cold start to pick the initial route without
  /// blocking the first frame on the full session load + native MLS init. Set
  /// by [save], cleared by [clear]; back-filled by [markExists] for sessions
  /// persisted before this flag existed.
  Future<bool> exists() async =>
      (await _storage.getString(_kExists)) != null;

  /// Back-fills the existence flag (upgrade path) so the next cold start
  /// resumes straight to the splash → chat list.
  Future<void> markExists() => _storage.putString(_kExists, '1');

  /// The "manually signed out" gate. Distinct from [exists]: after a
  /// non-destructive sign-out the session record stays on disk (so chat
  /// history, keys, and device identity survive) but this flag is set, so
  /// both the in-app router and the next cold start route to /welcome — where
  /// the user can resume in one tap — instead of auto-reconnecting. Cleared by
  /// [save] (fresh login) and on resume.
  Future<void> setSignedOut(bool value) => value
      ? _storage.putString(_kSignedOut, '1')
      : _storage.delete(_kSignedOut);

  /// Whether the user manually signed out while keeping their data on-device.
  /// See [setSignedOut].
  Future<bool> isSignedOut() async =>
      (await _storage.getString(_kSignedOut)) != null;
}
