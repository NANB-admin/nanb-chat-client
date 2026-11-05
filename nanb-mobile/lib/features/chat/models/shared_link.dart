import 'chat_message.dart';

/// One link found in a conversation, with the message it was sent in.
class SharedLink {
  const SharedLink({required this.url, required this.message});

  final String url;
  final ChatMessage message;
}
