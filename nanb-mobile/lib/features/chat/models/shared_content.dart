import 'chat_message.dart';
import 'shared_link.dart';

/// Everything shared in one conversation that still exists (not expired, not
/// deleted), newest first, split the way the "Media, links and files" screen
/// shows it. GIFs and stickers are deliberately excluded from [media].
class SharedContent {
  const SharedContent({
    this.media = const [],
    this.links = const [],
    this.files = const [],
  });

  /// Photos and videos.
  final List<ChatMessage> media;
  final List<SharedLink> links;
  final List<ChatMessage> files;
}
