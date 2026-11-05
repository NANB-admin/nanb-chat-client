import '../../../../features/chat/models/chat_message.dart';
import '../../../../features/chat/models/conversation.dart';
import '../../../../features/chat/models/conversation_kind.dart';
import '../../../../features/chat/models/crypto_mode.dart';
import '../../../../features/chat/models/group_member.dart';
import '../models/web_row.dart';
import 'row_values.dart';

/// Conversation <-> `conversations` row (same columns as the SQL table).
abstract final class ConversationRowCodec {
  static WebRow encode(Conversation c) => {
        'id': c.id,
        'peer_username': c.peerUsername,
        'peer_account_id': c.peerAccountId,
        'peer_device_id': c.peerDeviceId,
        'peer_identity_pub_key': List<int>.from(c.peerIdentityPubKey),
        'peer_x25519_pub_key': List<int>.from(c.peerX25519PubKey),
        'unread_count': c.unreadCount,
        'verified': RowValues.boolInt(c.verified),
        'crypto_mode': c.cryptoMode.name,
        'kind': c.kind.name,
        'group_name': c.groupName,
        'mls_epoch': c.mlsEpoch,
        'pending': RowValues.boolInt(c.pending),
        'pinned': RowValues.boolInt(c.pinned),
        'pinned_message_id': c.pinnedEnvelopeId,
        'group_avatar': c.groupAvatar,
        'muted': RowValues.boolInt(c.muted),
        'archived': RowValues.boolInt(c.archived),
        'blocked': RowValues.boolInt(c.blocked),
        'peer_blocks_screenshots': RowValues.boolInt(c.peerBlocksScreenshots),
        'peer_blocks_forwarding': RowValues.boolInt(c.peerBlocksForwarding),
        'disappearing_ttl': c.disappearingTtl,
      };

  static Conversation decode(
    WebRow row, {
    required List<ChatMessage> messages,
    required bool hasMoreOlderMessages,
    required List<GroupMember> members,
  }) {
    return Conversation(
      id: row['id'] as String,
      peerUsername: row['peer_username'] as String,
      peerAccountId: row['peer_account_id'] as String,
      peerDeviceId: row['peer_device_id'] as String,
      peerIdentityPubKey: RowValues.intList(row['peer_identity_pub_key']),
      peerX25519PubKey: RowValues.intList(row['peer_x25519_pub_key']),
      messages: messages,
      unreadCount: (row['unread_count'] as int?) ?? 0,
      verified: RowValues.flag(row['verified']),
      hasMoreOlderMessages: hasMoreOlderMessages,
      cryptoMode:
          CryptoMode.fromName((row['crypto_mode'] as String?) ?? 'ratchet'),
      kind: ConversationKind.fromName((row['kind'] as String?) ?? 'oneToOne'),
      groupName: row['group_name'] as String?,
      groupAvatar: row['group_avatar'] as String?,
      mlsEpoch: row['mls_epoch'] as int?,
      members: members,
      pending: RowValues.flag(row['pending']),
      pinned: RowValues.flag(row['pinned']),
      pinnedEnvelopeId: row['pinned_message_id'] as String?,
      muted: RowValues.flag(row['muted']),
      archived: RowValues.flag(row['archived']),
      blocked: RowValues.flag(row['blocked']),
      peerBlocksScreenshots: RowValues.flag(row['peer_blocks_screenshots']),
      peerBlocksForwarding: RowValues.flag(row['peer_blocks_forwarding']),
      disappearingTtl: (row['disappearing_ttl'] as int?) ?? -1,
    );
  }
}
