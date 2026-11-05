import '../../../../features/chat/models/group_member.dart';
import '../models/web_row.dart';
import 'row_values.dart';

/// GroupMember <-> `group_members` row.
abstract final class GroupMemberRowCodec {
  static WebRow encode(String conversationId, GroupMember m) => {
        'conversation_id': conversationId,
        'account_id': m.accountId,
        'username': m.username,
        'device_id': m.deviceId,
        'identity_pub_key': List<int>.from(m.identityPubKey),
        'x25519_pub_key': List<int>.from(m.x25519PubKey),
        'is_admin': RowValues.boolInt(m.isAdmin),
        'is_self': RowValues.boolInt(m.isSelf),
      };

  static GroupMember decode(WebRow row) => GroupMember(
        accountId: row['account_id'] as String,
        username: row['username'] as String,
        deviceId: row['device_id'] as String,
        identityPubKey: RowValues.intList(row['identity_pub_key']),
        x25519PubKey: RowValues.intList(row['x25519_pub_key']),
        isAdmin: RowValues.flag(row['is_admin']),
        isSelf: RowValues.flag(row['is_self']),
      );
}
