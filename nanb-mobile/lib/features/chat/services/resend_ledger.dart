import 'dart:convert';

import '../../../core/secure_storage/secure_storage.dart';
import '../models/resend_attempt.dart';

/// Durable state of [UnconfirmedMessageResender], so that neither its limits nor
/// a resend it still owes are lost when iOS suspends or kills the app.
///
/// A group change only arms an in-memory timer, so a process that dies before it
/// fires would forget the resend entirely, and that group change never happens
/// again. Attempt counts must survive too, or every launch would start the
/// budget over and re-send the same messages forever.
///
/// Bounded and best-effort: losing it costs at most some extra silent copies,
/// which the receiver dedups.
class ResendLedger {
  ResendLedger({
    required SecureStorage storage,
    int maxAttempts = _defaultMaxAttempts,
  })  : _storage = storage,
        _maxAttempts = maxAttempts;

  final SecureStorage _storage;
  final int _maxAttempts;

  static const String storageKey = 'send.resend_ledger';
  static const int _defaultMaxAttempts = 500;

  /// Client message id -> [count, lastAtMs]. Insertion-ordered: oldest go first.
  final Map<String, List<int>> _attempts = {};
  final Set<String> _pending = {};
  Future<void>? _loading;

  /// How often the message named [clientMsgId] has been re-sent.
  Future<ResendAttempt> attempt(String clientMsgId) async {
    await _ensureLoaded();
    final a = _attempts[clientMsgId];
    return a == null
        ? const ResendAttempt()
        : ResendAttempt(count: a[0], lastAtMs: a[1]);
  }

  /// Records one more resend of each of [clientMsgIds], in a single write.
  Future<void> recordAttempts(Iterable<String> clientMsgIds, DateTime at) async {
    await _ensureLoaded();
    for (final id in clientMsgIds) {
      final count = (_attempts.remove(id)?[0] ?? 0) + 1;
      _attempts[id] = [count, at.millisecondsSinceEpoch];
    }
    while (_attempts.length > _maxAttempts) {
      _attempts.remove(_attempts.keys.first);
    }
    await _write();
  }

  /// Conversations whose group changed and whose resend hasn't completed.
  Future<Set<String>> pendingConversations() async {
    await _ensureLoaded();
    return Set.of(_pending);
  }

  Future<void> markPending(String conversationId) async {
    await _ensureLoaded();
    if (_pending.add(conversationId)) await _write();
  }

  Future<void> clearPending(String conversationId) async {
    await _ensureLoaded();
    if (_pending.remove(conversationId)) await _write();
  }

  Future<void> _ensureLoaded() => _loading ??= _load();

  Future<void> _load() async {
    try {
      final raw = await _storage.getString(storageKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      final attempts = decoded['attempts'] as Map<String, dynamic>;
      attempts.forEach((id, value) {
        final pair = (value as List<dynamic>).cast<int>();
        _attempts[id] = pair;
      });
      _pending.addAll((decoded['pending'] as List<dynamic>).cast<String>());
    } catch (_) {/* unreadable: start over, at worst a few extra silent copies */}
  }

  Future<void> _write() async {
    try {
      await _storage.putString(
        storageKey,
        jsonEncode({'attempts': _attempts, 'pending': _pending.toList()}),
      );
    } catch (_) {/* best-effort; the next change retries it */}
  }
}
