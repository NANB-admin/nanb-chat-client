import '../models/chat_message.dart';

/// The narrow slice of `ConversationsNotifier` that delivering an OS share
/// needs: the four user-visible send paths, nothing else.
///
/// Same pattern as `NotifierServiceHost` — `ConversationsNotifier` implements
/// this directly (the signatures ARE its own), so `ShareDispatcher` can be
/// unit-tested against a small fake instead of standing up the whole notifier
/// with its database, crypto bridge, and transport.
abstract interface class ShareSendTarget {
  Future<void> sendMessage({
    required String conversationId,
    required String myDeviceId,
    required String text,
    ChatMessage? replyTo,
  });

  Future<void> sendImage({
    required String conversationId,
    required String myDeviceId,
    required List<int> imageBytes,
    required String mimeType,
    String caption,
    bool forwarded,
  });

  Future<void> sendVideo({
    required String conversationId,
    required String myDeviceId,
    required List<int> videoBytes,
    required String mimeType,
    String caption,
    bool forwarded,
  });

  Future<void> sendFile({
    required String conversationId,
    required String myDeviceId,
    required List<int> fileBytes,
    required String mimeType,
    required String filename,
    bool forwarded,
  });
}
