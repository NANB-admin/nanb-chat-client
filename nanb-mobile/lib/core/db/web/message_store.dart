import '../../../features/chat/models/chat_message.dart';
import '../../../features/chat/models/message_kind.dart';
import 'codecs/message_row_codec.dart';
import 'messages_web_table.dart';
import 'models/web_row.dart';

/// `messages` table logic: the same queries, ordering and limits as the SQL
/// implementation. Ties on `server_ts` fall back to insertion (rowid) order.
class MessageStore {
  MessageStore(this._table);

  final MessagesWebTable _table;

  void upsertAll(String conversationId, List<ChatMessage> messages) {
    for (final m in messages) {
      _table.put(m.envelopeId, MessageRowCodec.encode(conversationId, m));
    }
  }

  ChatMessage? get(String envelopeId) {
    final row = _table.get(envelopeId);
    return row == null ? null : MessageRowCodec.decode(row);
  }

  void delete(String envelopeId) => _table.remove(envelopeId);

  void deleteForConversation(String conversationId) {
    for (final id in _idsIn(conversationId)) {
      _table.remove(id);
    }
  }

  bool hasClientId(
    String conversationId,
    String senderDeviceId,
    String clientMsgId,
  ) {
    return _table.inConversation(conversationId).any((r) =>
        r['sender_device_id'] == senderDeviceId &&
        r['client_msg_id'] == clientMsgId);
  }

  /// The newest [limit] messages (optionally strictly older than
  /// [beforeServerTsMs]), ascending.
  List<ChatMessage> page(
    String conversationId, {
    required int limit,
    int? beforeServerTsMs,
  }) {
    if (limit <= 0) return const [];
    var rows = _ascending(_table.inConversation(conversationId));
    if (beforeServerTsMs != null) {
      rows = rows
          .where((r) => (r['server_ts'] as int) < beforeServerTsMs)
          .toList();
    }
    return _tail(rows, limit).map(MessageRowCodec.decode).toList();
  }

  /// The newest [probe] messages of [conversationId] as raw rows, ascending.
  List<WebRow> recentRows(String conversationId, int probe) =>
      _tail(_ascending(_table.inConversation(conversationId)), probe);

  /// Case-insensitive substring search over `text` messages, newest first,
  /// capped to the newest [limit].
  List<ChatMessage> search(String conversationId, String query, int limit) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty || limit <= 0) return const [];
    final hits = _table.inConversation(conversationId).where((r) =>
        r['kind'] == MessageKind.text.name &&
        (r['body'] as String).toLowerCase().contains(q));
    return _tail(_ascending(hits), limit)
        .reversed
        .map(MessageRowCodec.decode)
        .toList();
  }

  /// Keeps only the newest [keep] messages of [conversationId]. A negative
  /// [keep] is a no-op (SQLite treats `LIMIT -1` as unlimited).
  void trim(String conversationId, int keep) {
    if (keep < 0) return;
    final sorted = _ascending(_table.inConversation(conversationId));
    if (sorted.length <= keep) return;
    for (final row in sorted.sublist(0, sorted.length - keep)) {
      _table.remove(row['envelope_id'] as String);
    }
  }

  /// Removes messages whose `server_ts + ttl` is at/before [nowMs]; the TTL per
  /// message comes from [conversationTtlSeconds] (override when > 0) else
  /// [globalTtlSeconds]. Returns rows removed.
  int deletePastRetention(
    int nowMs,
    int? globalTtlSeconds,
    int Function(String conversationId) conversationTtlSeconds,
  ) {
    final doomed = <String>[];
    for (final convo in _table.conversationIds.toList()) {
      final override = conversationTtlSeconds(convo);
      final effective = override > 0 ? override : globalTtlSeconds;
      if (effective == null) continue;
      for (final r in _table.inConversation(convo)) {
        if (nowMs >= (r['server_ts'] as int) + effective * 1000) {
          doomed.add(r['envelope_id'] as String);
        }
      }
    }
    doomed.forEach(_table.remove);
    return doomed.length;
  }

  /// Removes messages whose own `expires_at` is at/before [nowMs].
  int deleteExpired(int nowMs) {
    final doomed = <String>[
      for (final r in _table.rows)
        if (r['expires_at'] != null && (r['expires_at'] as int) <= nowMs)
          r['envelope_id'] as String,
    ];
    doomed.forEach(_table.remove);
    return doomed.length;
  }

  List<String> _idsIn(String conversationId) => [
        for (final r in _table.inConversation(conversationId))
          r['envelope_id'] as String,
      ];

  /// Ascending by `server_ts`, ties kept in insertion order (stable).
  List<WebRow> _ascending(Iterable<WebRow> rows) {
    final indexed = rows.toList().asMap().entries.toList()
      ..sort((a, b) {
        final c = (a.value['server_ts'] as int)
            .compareTo(b.value['server_ts'] as int);
        return c != 0 ? c : a.key.compareTo(b.key);
      });
    return [for (final e in indexed) e.value];
  }

  List<WebRow> _tail(List<WebRow> rows, int n) =>
      rows.length > n ? rows.sublist(rows.length - n) : rows;
}
