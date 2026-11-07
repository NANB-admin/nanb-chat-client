import 'dart:convert';

import '../../../core/secure_storage/secure_storage.dart';

/// Durable record of when each 1:1's current MLS group came into being here.
///
/// Anything sent before that moment was sealed to an earlier group and can never
/// be opened, however healthy the current one is. Counting those failures as
/// evidence of a broken group made a device tear down the group it had just
/// joined, which re-keys the chat for both sides and strands whatever is in
/// flight, so that catching up after one rebuild could cause the next.
///
/// Durable because a catchup after a restart replays exactly those old envelopes.
/// Best-effort: losing an entry only means old envelopes count as they used to.
class GroupEstablishedLog {
  GroupEstablishedLog({
    required SecureStorage storage,
    int maxEntries = _defaultMaxEntries,
  })  : _storage = storage,
        _maxEntries = maxEntries;

  final SecureStorage _storage;
  final int _maxEntries;

  static const String storageKey = 'mls.group_established_at';
  static const int _defaultMaxEntries = 500;

  /// Conversation id -> ms since epoch. Insertion-ordered: oldest go first.
  final Map<String, int> _atMs = {};
  Future<void>? _loading;

  /// When [conversationId]'s current group was established, if known.
  Future<DateTime?> at(String conversationId) async {
    await _ensureLoaded();
    final ms = _atMs[conversationId];
    return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
  }

  /// Records that [conversationId]'s current group was established at [at].
  Future<void> mark(String conversationId, DateTime at) async {
    await _ensureLoaded();
    _atMs.remove(conversationId);
    _atMs[conversationId] = at.millisecondsSinceEpoch;
    while (_atMs.length > _maxEntries) {
      _atMs.remove(_atMs.keys.first);
    }
    try {
      await _storage.putString(storageKey, jsonEncode(_atMs));
    } catch (_) {/* best-effort; the next mark retries it */}
  }

  Future<void> _ensureLoaded() => _loading ??= _load();

  Future<void> _load() async {
    try {
      final raw = await _storage.getString(storageKey);
      if (raw == null || raw.isEmpty) return;
      (jsonDecode(raw) as Map<String, dynamic>).forEach((id, value) {
        if (value is int) _atMs[id] = value;
      });
    } catch (_) {/* unreadable: old envelopes count as they used to */}
  }
}
