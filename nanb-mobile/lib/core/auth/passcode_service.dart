import 'dart:convert';
import 'dart:isolate';
import 'dart:math';

import 'package:cryptography/cryptography.dart';

import '../platform/monotonic_clock.dart';
import '../secure_storage/secure_storage.dart';

/// Manages the app passcode — a short numeric PIN the user sets in-app to gate
/// opening the app (Robinhood-style), independent of the device biometric lock.
///
/// The PIN is never stored in the clear: a random 16-byte salt + a PBKDF2-
/// HMAC-SHA256 derivation (100k iterations) are kept in [SecureStorage]
/// (hardware-backed on device). A short numeric PIN is inherently low-entropy,
/// so this is a convenience/shoulder-surfing gate — the real data protection is
/// the SQLCipher DB key in the OS keystore, which the PIN does NOT derive.
class PasscodeService {
  PasscodeService(
    this._storage, {
    DateTime Function()? now,
    Future<int?> Function()? monotonicMs,
  })  : _now = now ?? DateTime.now,
        _monotonicMs = monotonicMs ?? MonotonicClock.elapsedRealtimeMs;

  final SecureStorage _storage;

  /// Wall clock — the human-facing "try again in …" and the fallback lockout
  /// clock. Injectable for tests.
  final DateTime Function() _now;

  /// Boot-relative monotonic ms (null when unavailable). The lockout deadline is
  /// tracked on BOTH this and the wall clock; a lockout ends only once BOTH have
  /// elapsed, so rolling the wall clock forward can't skip the wait. Injectable
  /// for tests.
  final Future<int?> Function() _monotonicMs;

  static const _kSalt = 'passcode.salt.b64';
  static const _kHash = 'passcode.hash.b64';
  static const _kFails = 'passcode.fails';
  static const _kLockUntilMs = 'passcode.lock_until_ms';
  // Monotonic (boot-relative) lockout deadline + the monotonic reading taken
  // when the lockout started — the latter lets us detect a reboot (which resets
  // the monotonic clock) and fall back to the wall-clock deadline.
  static const _kLockUntilElapsed = 'passcode.lock_until_elapsed';
  static const _kLockStartElapsed = 'passcode.lock_start_elapsed';
  static const _iterations = 100000;

  /// Wrong attempts before the escalating lockout kicks in.
  static const int _lockoutThreshold = 5;

  /// Fixed PIN length (digits). Fixed so the lock screen can auto-submit
  /// without storing the length, and avoids leaking it.
  static const int length = 6;

  // Static so `_derive` can reference it from inside `Isolate.run` without
  // capturing `this` (which holds non-sendable storage/clock closures); on the
  // spawned isolate it lazily re-inits. The config is pure/constant.
  static final Pbkdf2 _pbkdf2 = Pbkdf2(
    macAlgorithm: Hmac.sha256(),
    iterations: _iterations,
    bits: 256,
  );

  /// True when a passcode hash is stored.
  Future<bool> isSet() async => (await _storage.getString(_kHash)) != null;

  /// Sets (or replaces) the passcode. Throws [ArgumentError] for a PIN outside
  /// the allowed length or containing non-digits.
  Future<void> setPasscode(String pin) async {
    _validate(pin);
    final salt = _randomBytes(16);
    final hash = await _derive(pin, salt);
    await _storage.putString(_kSalt, base64.encode(salt));
    await _storage.putString(_kHash, base64.encode(hash));
    await _resetAttempts();
  }

  /// Verifies [pin] against the stored hash. Returns false if no passcode is
  /// set, the PIN doesn't match, or attempts are currently locked out.
  /// Constant-time compare on the derived bytes. Wrong attempts accumulate an
  /// escalating lockout (persisted, so relaunching can't reset it) — a stolen
  /// phone can't brute-force the low-entropy PIN by hammering attempts.
  Future<bool> verify(String pin) async {
    if (await lockoutRemaining() != null) return false; // throttled
    final saltB64 = await _storage.getString(_kSalt);
    final hashB64 = await _storage.getString(_kHash);
    if (saltB64 == null || hashB64 == null) return false;
    final candidate = await _derive(pin, base64.decode(saltB64));
    final ok = _constantTimeEquals(candidate, base64.decode(hashB64));
    if (ok) {
      await _resetAttempts();
      return true;
    }
    await _registerFailure();
    return false;
  }

  /// The remaining lockout window after too many wrong attempts, or null when
  /// attempts are currently allowed. Callers can surface a "try again in …"
  /// message.
  Future<Duration?> lockoutRemaining() async {
    final raw = await _storage.getString(_kLockUntilMs);
    if (raw == null) return null;
    final wallUntil = int.tryParse(raw) ?? 0;
    var remaining =
        wallUntil - _now().millisecondsSinceEpoch; // wall remaining (may be <=0)

    // Monotonic remaining: unaffected by wall-clock changes, so rolling the
    // clock forward can't shrink it. The lockout ends only once BOTH clocks
    // agree, so take the LARGER remaining.
    final nowElapsed = await _monotonicMs();
    final elapsedUntil =
        int.tryParse(await _storage.getString(_kLockUntilElapsed) ?? '');
    final elapsedStart =
        int.tryParse(await _storage.getString(_kLockStartElapsed) ?? '');
    if (nowElapsed != null && elapsedUntil != null && elapsedStart != null) {
      if (nowElapsed >= elapsedStart) {
        // No reboot — the monotonic clock is authoritative (can't be rolled).
        final monoRemaining = elapsedUntil - nowElapsed;
        if (monoRemaining > remaining) remaining = monoRemaining;
      } else {
        // Reboot detected (uptime jumped BACKWARDS). Do NOT fall back to the
        // attacker-settable wall clock — that let a reboot + clock-roll skip the
        // wait. Instead FAIL CLOSED: re-anchor the FULL current lockout on the
        // fresh monotonic clock, so a reboot merely restarts a wait it can never
        // shorten. (Rare cost: an honest reboot during a lockout waits again.)
        final fails =
            int.tryParse(await _storage.getString(_kFails) ?? '') ?? 0;
        final lock = _lockoutFor(fails);
        if (lock != null) {
          await _storage.putString(_kLockStartElapsed, nowElapsed.toString());
          await _storage.putString(_kLockUntilElapsed,
              (nowElapsed + lock.inMilliseconds).toString());
          if (lock.inMilliseconds > remaining) remaining = lock.inMilliseconds;
        }
      }
    }

    if (remaining <= 0) return null;
    return Duration(milliseconds: remaining);
  }

  /// Removes the stored passcode.
  Future<void> clear() async {
    await _storage.delete(_kSalt);
    await _storage.delete(_kHash);
    await _resetAttempts();
  }

  Future<void> _resetAttempts() async {
    await _storage.delete(_kFails);
    await _storage.delete(_kLockUntilMs);
    await _storage.delete(_kLockUntilElapsed);
    await _storage.delete(_kLockStartElapsed);
  }

  Future<void> _registerFailure() async {
    final fails =
        (int.tryParse(await _storage.getString(_kFails) ?? '') ?? 0) + 1;
    await _storage.putString(_kFails, fails.toString());
    final lock = _lockoutFor(fails);
    if (lock == null) return;
    final lockMs = lock.inMilliseconds;
    // Wall-clock deadline (human-facing + fallback / post-reboot).
    await _storage.putString(
        _kLockUntilMs, (_now().millisecondsSinceEpoch + lockMs).toString());
    // Monotonic deadline — the tamper-resistant one. If the platform can't give
    // a monotonic reading, clear any stale values so the wall clock governs.
    final nowElapsed = await _monotonicMs();
    if (nowElapsed != null) {
      await _storage.putString(_kLockStartElapsed, nowElapsed.toString());
      await _storage.putString(
          _kLockUntilElapsed, (nowElapsed + lockMs).toString());
    } else {
      await _storage.delete(_kLockStartElapsed);
      await _storage.delete(_kLockUntilElapsed);
    }
  }

  /// Escalating lockout once wrong attempts reach [_lockoutThreshold]; null
  /// below it. Grows 30s → 1m → 5m → 15m → 30m and holds at the cap.
  static Duration? _lockoutFor(int fails) {
    if (fails < _lockoutThreshold) return null;
    const steps = [
      Duration(seconds: 30),
      Duration(minutes: 1),
      Duration(minutes: 5),
      Duration(minutes: 15),
      Duration(minutes: 30),
    ];
    final idx = (fails - _lockoutThreshold).clamp(0, steps.length - 1);
    return steps[idx];
  }

  Future<List<int>> _derive(String pin, List<int> salt) async {
    // PBKDF2 (100k HMAC-SHA256) is CPU-heavy (hundreds of ms) — run it on a
    // background isolate so the lock screen doesn't freeze on every unlock. The
    // captured `pin` (String) + `salt` (List<int>) are sendable; `_pbkdf2` is
    // static so `this` is not captured.
    return Isolate.run(() async {
      final key = await _pbkdf2.deriveKey(
        secretKey: SecretKey(utf8.encode(pin)),
        nonce: salt,
      );
      return key.extractBytes();
    });
  }

  static void _validate(String pin) {
    if (pin.length != length) {
      throw ArgumentError('passcode must be $length digits');
    }
    if (!RegExp(r'^\d+$').hasMatch(pin)) {
      throw ArgumentError('passcode must be digits only');
    }
  }

  static List<int> _randomBytes(int n) {
    final rng = Random.secure();
    return List<int>.generate(n, (_) => rng.nextInt(256));
  }

  static bool _constantTimeEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }
}
