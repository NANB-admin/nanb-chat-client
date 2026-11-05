import 'package:nanb_chat/core/db/app_database.dart';
import 'package:nanb_chat/features/chat/models/chat_message.dart';
import 'package:nanb_chat/features/chat/models/conversation.dart';
import 'package:nanb_chat/features/chat/models/conversation_kind.dart';
import 'package:nanb_chat/features/chat/services/notifier_service_host.dart';

const stateConvoId = '1to1:a:b';
const stateMyDevice = 'dev-me';
const stateSiblingDevice = 'dev-sibling';
const statePeerDevice = 'dev-peer';

/// DB fake: an in-memory message list with the paging contract of
/// `loadMessages` (strictly older than the cursor, newest `limit`, ascending).
class StateFakeDb implements AppDatabase {
  final List<ChatMessage> rows = [];
  final upserted = <Conversation>[];

  @override
  Future<void> upsertConversation(Conversation conversation) async =>
      upserted.add(conversation);

  @override
  Future<List<ChatMessage>> loadMessages(String conversationId,
      {required int limit, int? beforeServerTsMs}) async {
    final all = rows
        .where((m) =>
            beforeServerTsMs == null ||
            m.serverTs.millisecondsSinceEpoch < beforeServerTsMs)
        .toList()
      ..sort((a, b) => a.serverTs.compareTo(b.serverTs));
    return all.length <= limit ? all : all.sublist(all.length - limit);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

class StateFakeHost implements NotifierServiceHost {
  StateFakeHost(this.convo);

  Conversation? convo;
  @override
  final StateFakeDb db = StateFakeDb();
  final selfControls = <String>[];
  final deletedConversations = <String>[];
  int notifications = 0;
  bool selfSendThrows = false;

  @override
  Conversation? conversation(String id) => convo?.id == id ? convo : null;

  @override
  Iterable<Conversation> allConversations() => [?convo];

  @override
  void setConversation(String id, Conversation conversation) =>
      convo = conversation;

  @override
  void notifyHost() => notifications++;

  @override
  Future<String> selfDeviceId() async => stateMyDevice;

  @override
  Future<bool> isMyDeviceWarm(String deviceId, String myDeviceId) async =>
      deviceId == myDeviceId || deviceId == stateSiblingDevice;

  @override
  Future<void> sendSelfControl(String conversationId, String body) async {
    if (selfSendThrows) throw StateError('offline');
    selfControls.add(body);
  }

  @override
  Future<void> deleteConversation(String conversationId) async {
    deletedConversations.add(conversationId);
    convo = null;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

ChatMessage stateMsg(String id, int tsMs,
        {bool mine = false, String conversationId = stateConvoId}) =>
    ChatMessage(
      envelopeId: id,
      conversationId: conversationId,
      senderDeviceId: mine ? stateMyDevice : statePeerDevice,
      body: 'hi',
      serverTs: DateTime.fromMillisecondsSinceEpoch(tsMs, isUtc: true),
      mine: mine,
    );

Conversation stateConvo(
        {List<ChatMessage> messages = const [], int unread = 0}) =>
    Conversation(
      id: stateConvoId,
      peerUsername: '@bob',
      peerAccountId: 'acc-bob',
      peerDeviceId: statePeerDevice,
      peerIdentityPubKey: const [1],
      messages: messages,
      unreadCount: unread,
    );

Conversation stateGroupConvo() => Conversation(
      id: stateConvoId,
      peerUsername: '',
      peerAccountId: '',
      peerDeviceId: '',
      peerIdentityPubKey: const [],
      messages: const [],
      unreadCount: 0,
      kind: ConversationKind.group,
    );
