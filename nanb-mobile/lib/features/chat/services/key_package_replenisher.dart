import '../../../core/crypto/crypto_bridge.dart';
import '../../../core/network/api_client.dart';
import '../../../core/secure_storage/secure_storage.dart';

/// Refills this device's published MLS KeyPackage pool when it runs low, so
/// peers' future add-to-group attempts don't 410 on an exhausted pool. Spec
/// §6.5: low-water = 10, refill batch = 50. Failures are non-fatal (retried on
/// the next foreground / reconnect). Extracted from `ConversationsNotifier`.
class KeyPackageReplenisher {
  KeyPackageReplenisher({
    required ApiClient api,
    required CryptoBridge crypto,
    SecureStorage? storage,
  })  : _api = api,
        _crypto = crypto,
        _storage = storage;

  final ApiClient _api;
  final CryptoBridge _crypto;

  /// Durable home for [_pendingResetPublish]. Optional so existing callers and
  /// tests keep working; without it the marker is process-lifetime only, which
  /// is the pre-existing behaviour.
  final SecureStorage? _storage;

  /// SecureStorage key holding the "a store reset still needs its replacing
  /// publish" marker. Present (any value) means pending.
  static const String pendingResetPublishKey = 'mls.pending_reset_publish';

  static const int _lowWaterMark = 10;
  static const int _refillSize = 50;

  /// Set when the native side reported a store reset but the replacing publish
  /// hasn't succeeded yet, so a failed attempt is retried on the next
  /// foreground instead of being lost with the one-shot native flag.
  bool _pendingResetPublish = false;

  /// Whether the marker has been read back from storage this run.
  bool _hydrated = false;

  /// Tops up the published KeyPackage pool if it has dropped below the
  /// low-water mark, and REPLACES it outright when the local MLS store has
  /// been rebuilt. No-op (best-effort) on any failure.
  Future<void> replenishIfNeeded() async {
    try {
      // Validity before quantity. A rebuilt store leaves every published
      // package dead — its private key is gone — but the pool still reads as
      // FULL, so the low-water check below would never fire and peers would go
      // on drawing dead packages, making each new conversation undecryptable
      // until all ~100 are burnt one failed invitation at a time. `reset: true`
      // makes the server DROP them; publishing more would not help, because
      // PopOne is FIFO and hands out the dead ones first.
      if (await _replacePoolIfStoreWasReset()) return;
      final remaining = await _api.keyPackageCount();
      if (remaining >= _lowWaterMark) return;
      final kps = await _crypto.mintKeyPackages(count: _refillSize);
      await _api.publishKeyPackages(kps);
    } catch (e) {
      // ignore: avoid_print
      print(
          'KeyPackage replenishment failed: $e — will retry on next foreground');
    }
  }

  /// A peer's Welcome turned out to be built from a package this device can no
  /// longer open, so treat the published pool as dead and replace it. This repairs
  /// a store reset whose one-shot native flag never reached the replacing publish.
  /// At most one replacement per [_deadPoolCooldown].
  Future<void> replaceSuspectPool() async {
    final now = DateTime.now();
    final last = _lastSuspectReplace;
    if (last != null && now.difference(last) < _deadPoolCooldown) return;
    _lastSuspectReplace = now;
    try {
      await _setPendingReset(true);
      await _replacePoolIfStoreWasReset();
    } catch (e) {
      // ignore: avoid_print
      print('KeyPackage replacement failed: $e — will retry on next foreground');
    }
  }

  DateTime? _lastSuspectReplace;
  static const Duration _deadPoolCooldown = Duration(minutes: 10);

  /// Replaces the pool if the local store was rebuilt, and does nothing else. Run
  /// this BEFORE draining a catchup: that drain is what makes a peer rebuild the
  /// chat, and every Welcome it builds from the old pool can never be opened.
  Future<void> replaceIfStoreWasReset() async {
    try {
      await _replacePoolIfStoreWasReset();
    } catch (e) {
      // ignore: avoid_print
      print('KeyPackage replacement failed: $e — will retry on next foreground');
    }
  }

  /// True when it replaced the pool. Throws if the publish fails, leaving the
  /// marker set so the next attempt retries.
  ///
  /// Single-flight: a resume and a reconnect can both land here, and a second
  /// publish would throw away the packages the first just uploaded.
  Future<bool> _replacePoolIfStoreWasReset() {
    final running = _replacing;
    if (running != null) return running;
    final started = _replaceOnce().whenComplete(() => _replacing = null);
    _replacing = started;
    return started;
  }

  Future<bool>? _replacing;

  Future<bool> _replaceOnce() async {
    await _hydratePendingReset();
    if (await _crypto.consumeMlsStoreReset()) {
      await _setPendingReset(true);
    }
    if (!_pendingResetPublish) return false;
    final fresh = await _crypto.mintKeyPackages(count: _refillSize);
    await _api.publishKeyPackages(fresh, reset: true);
    // Only now: the native flag is one-shot, so clearing before the publish
    // landed would strand the device on a dead pool forever.
    await _setPendingReset(false);
    return true;
  }

  /// Reads the persisted marker once per process.
  ///
  /// The native store-reset flag is ONE-SHOT: consuming it and then dying
  /// before `publishKeyPackages(reset: true)` succeeds (a crash, an OS kill, a
  /// force-quit mid-publish) used to lose the fact that a reset ever happened —
  /// leaving the device on a pool of dead packages with nothing left to notice
  /// it. Persisting the marker closes that window: the retry survives the kill.
  Future<void> _hydratePendingReset() async {
    if (_hydrated) return;
    _hydrated = true;
    final storage = _storage;
    if (storage == null) return;
    try {
      _pendingResetPublish = await storage.getString(pendingResetPublishKey) != null;
    } catch (_) {/* best-effort: fall back to the in-memory marker */}
  }

  /// Updates the marker in memory AND on disk, so it survives a process kill.
  Future<void> _setPendingReset(bool pending) async {
    _pendingResetPublish = pending;
    final storage = _storage;
    if (storage == null) return;
    try {
      if (pending) {
        await storage.putString(pendingResetPublishKey, '1');
      } else {
        await storage.delete(pendingResetPublishKey);
      }
    } catch (_) {/* best-effort: the in-memory marker still covers this run */}
  }
}
