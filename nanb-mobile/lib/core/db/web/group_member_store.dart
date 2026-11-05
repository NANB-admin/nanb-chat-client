import '../../../features/chat/models/group_member.dart';
import 'codecs/group_member_row_codec.dart';
import 'models/web_row.dart';
import 'web_table.dart';

/// `group_members` table logic, keyed by (conversation_id, device_id).
class GroupMemberStore {
  GroupMemberStore(this._table);

  final WebTable _table;

  static String _key(String conversationId, String deviceId) =>
      '$conversationId\u0000$deviceId';

  /// Replaces the full membership of [conversationId]. A duplicate device id in
  /// [members] replaces the earlier one (the SQL insert would violate the PK;
  /// last-wins is the lenient equivalent).
  void replaceAll(String conversationId, List<GroupMember> members) {
    deleteForConversation(conversationId);
    for (final m in members) {
      _table.put(_key(conversationId, m.deviceId),
          GroupMemberRowCodec.encode(conversationId, m));
    }
  }

  List<GroupMember> forConversation(String conversationId) =>
      _rowsOf(conversationId).map(GroupMemberRowCodec.decode).toList();

  /// Every conversation's members, bucketed by conversation id.
  Map<String, List<GroupMember>> byConversation() {
    final out = <String, List<GroupMember>>{};
    for (final row in _table.rows) {
      (out[row['conversation_id'] as String] ??= <GroupMember>[])
          .add(GroupMemberRowCodec.decode(row));
    }
    return out;
  }

  void delete(String conversationId, String deviceId) =>
      _table.remove(_key(conversationId, deviceId));

  void deleteForConversation(String conversationId) {
    final keys = [
      for (final e in _table.entries)
        if (e.value['conversation_id'] == conversationId) e.key,
    ];
    keys.forEach(_table.remove);
  }

  List<WebRow> _rowsOf(String conversationId) => [
        for (final row in _table.rows)
          if (row['conversation_id'] == conversationId) row,
      ];
}
