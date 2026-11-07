import 'dart:convert';

import '../../../core/secure_storage/secure_storage.dart';

/// Limits how often this device may rebuild a 1:1's MLS group.
///
/// A rebuild re-keys the chat for both sides and strands whatever is in flight,
/// so a chat that keeps rebuilding can never settle, whatever the reason. The
/// old limit was a flat 45 seconds held in memory: it reset on every launch and
/// did not grow. Now each further rebuild waits longer, across restarts, until a
/// message decrypts again. Re-sends recover what is sent during the wait.
class RebuildThrottle {
  RebuildThrottle({
    required SecureStorage storage,
    DateTime Function()? clock,
    List<Duration> Function()? waits,
    int maxEntries = _defaultMaxEntries,
  })  : _storage = storage,
        _clock = clock ?? (() => DateTime.now().toUtc()),
        _waits = waits ?? (() => defaultWaits),
        _maxEntries = maxEntries;

  final SecureStorage _storage;
  final DateTime Function() _clock;
  final List<Duration> Function() _waits;
  final int _maxEntries;

  static const String storageKey = 'mls.rebuild_throttle';
  static const int _defaultMaxEntries = 500;

  /// The wait after the 1st, 2nd, 3rd and every later rebuild in a run.
  static const List<Duration> defaultWaits = [
    Duration(seconds: 45),
    Duration(minutes: 2),
    Duration(minutes: 5),
    Duration(minutes: 15),
  ];

  /// A chat that has been quiet this long starts a new run.
  static const Duration _forgetAfter = Duration(hours: 1);

  /// Conversation id -> [rebuilds in this run, last rebuild ms].
  final Map<String, List<int>> _runs = {};
  Future<void>? _loading;

  /// Whether [conversationId] may be rebuilt now.
  Future<bool> allows(String conversationId) async =>
      await remainingWait(conversationId) == Duration.zero;

  /// How long until [conversationId] may be rebuilt; zero when it may be now.
  Future<Duration> remainingWait(String conversationId) async {
    await _ensureLoaded();
    final run = _runs[conversationId];
    if (run == null) return Duration.zero;
    final since = _clock().difference(
        DateTime.fromMillisecondsSinceEpoch(run[1], isUtc: true));
    if (since >= _forgetAfter) return Duration.zero;
    final waits = _waits();
    final wait = waits[(run[0] - 1).clamp(0, waits.length - 1)];
    return since >= wait ? Duration.zero : wait - since;
  }

  /// Records a rebuild of [conversationId] happening now.
  Future<void> record(String conversationId) async {
    await _ensureLoaded();
    final now = _clock();
    final previous = _runs.remove(conversationId);
    final stale = previous == null ||
        now.difference(DateTime.fromMillisecondsSinceEpoch(previous[1],
                isUtc: true)) >=
            _forgetAfter;
    _runs[conversationId] = [
      stale ? 1 : previous[0] + 1,
      now.millisecondsSinceEpoch,
    ];
    while (_runs.length > _maxEntries) {
      _runs.remove(_runs.keys.first);
    }
    await _write();
  }

  /// A message decrypted, so the group works and the run is over.
  Future<void> clear(String conversationId) async {
    await _ensureLoaded();
    if (_runs.remove(conversationId) != null) await _write();
  }

  Future<void> _ensureLoaded() => _loading ??= _load();

  Future<void> _load() async {
    try {
      final raw = await _storage.getString(storageKey);
      if (raw == null || raw.isEmpty) return;
      (jsonDecode(raw) as Map<String, dynamic>).forEach((id, value) {
        _runs[id] = (value as List<dynamic>).cast<int>();
      });
    } catch (_) {/* unreadable: every chat may rebuild once, as a fresh start */}
  }

  Future<void> _write() async {
    try {
      await _storage.putString(storageKey, jsonEncode(_runs));
    } catch (_) {/* best-effort; the next change retries it */}
  }
}
