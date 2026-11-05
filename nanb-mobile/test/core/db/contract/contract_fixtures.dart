import 'package:nanb_chat/core/crypto/conversation_crypto_state.dart';
import 'package:nanb_chat/core/db/app_database.dart';
import 'package:nanb_chat/features/chat/models/chat_message.dart';
import 'package:nanb_chat/features/chat/models/conversation.dart';
import 'package:nanb_chat/features/chat/models/conversation_kind.dart';
import 'package:nanb_chat/features/chat/models/crypto_mode.dart';
import 'package:nanb_chat/features/chat/models/group_member.dart';
import 'package:nanb_chat/features/chat/models/message_kind.dart';

/// Creates a database via [create] and opens it.
Future<AppDatabase> openDb(AppDatabase Function() create) async {
  final db = create();
  await db.open(masterKeyHex: 'aa' * 32);
  return db;
}

Conversation convo(
  String id, {
  int unread = 0,
  ConversationKind kind = ConversationKind.oneToOne,
  String? groupName,
  int? mlsEpoch,
  CryptoMode cryptoMode = CryptoMode.ratchet,
  int disappearingTtl = -1,
  bool pinned = false,
  String? pinnedEnvelopeId,
  bool pending = false,
}) {
  return Conversation(
    id: id,
    peerUsername: 'user-$id',
    peerAccountId: '$id-acc',
    peerDeviceId: '$id-dev',
    peerIdentityPubKey: const [1, 2, 3],
    peerX25519PubKey: const [4, 5, 6],
    messages: const [],
    unreadCount: unread,
    kind: kind,
    groupName: groupName,
    mlsEpoch: mlsEpoch,
    cryptoMode: cryptoMode,
    disappearingTtl: disappearingTtl,
    pinned: pinned,
    pinnedEnvelopeId: pinnedEnvelopeId,
    pending: pending,
  );
}

ChatMessage msg(
  String envelopeId,
  int tsMs, {
  String convoId = 'c1',
  String body = 'hello',
  MessageKind kind = MessageKind.text,
  String sender = 'dev-a',
  String? clientMsgId,
  DateTime? expiresAt,
}) {
  return ChatMessage(
    envelopeId: envelopeId,
    conversationId: convoId,
    senderDeviceId: sender,
    body: body,
    serverTs: DateTime.fromMillisecondsSinceEpoch(tsMs, isUtc: true),
    mine: false,
    kind: kind,
    clientMsgId: clientMsgId,
    expiresAt: expiresAt,
  );
}

GroupMember member(String deviceId, {bool admin = false}) => GroupMember(
      accountId: 'acc-$deviceId',
      username: 'name-$deviceId',
      deviceId: deviceId,
      identityPubKey: const [9, 9],
      x25519PubKey: const [8, 8],
      isAdmin: admin,
      isSelf: false,
    );

ConversationCryptoState cryptoState(
  String convoId, {
  String peer = '',
  int send = 1,
}) =>
    ConversationCryptoState(
      conversationId: convoId,
      peerDeviceId: peer,
      sendCounter: send,
      sendChainKey: const [1, 1],
      recvCounter: 2,
      recvChainKey: const [2, 2],
    );

List<String> ids(List<ChatMessage> messages) =>
    messages.map((m) => m.envelopeId).toList();

/// Stores [count] messages `m0..m{count-1}` with ascending timestamps
/// (1000 ms apart, starting at 1000) in [convoId].
Future<void> seedMessages(AppDatabase db, int count,
    {String convoId = 'c1'}) async {
  await db.upsertConversation(convo(convoId));
  await db.upsertMessages(convoId, [
    for (var i = 0; i < count; i++)
      msg(convoId == 'c1' ? 'm$i' : '$convoId:m$i', 1000 + i * 1000,
          convoId: convoId),
  ]);
}
