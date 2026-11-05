import '../models/chat_message.dart';
import '../models/message_kind.dart';
import '../models/shared_content.dart';
import '../models/shared_link.dart';
import 'sticker_marker.dart';

/// Loads one page of stored messages older than [beforeServerTsMs] (or the
/// newest page when null), in ascending order — the shape of
/// `AppDatabase.loadMessages`.
typedef MessagePageLoader = Future<List<ChatMessage>> Function({
  required int limit,
  int? beforeServerTsMs,
});

/// Builds a conversation's [SharedContent] from its stored messages.
class SharedContentLoader {
  SharedContentLoader({this.pageSize = 500, DateTime Function()? now})
      : _now = now ?? DateTime.now;

  final int pageSize;
  final DateTime Function() _now;

  static final RegExp _url =
      RegExp(r"(?:https?://|www\.)[^\s<>']+", caseSensitive: false);

  /// Walks the whole stored history, newest page first, until it is exhausted.
  Future<SharedContent> load(MessagePageLoader loadPage) async {
    final all = <ChatMessage>[];
    int? cursor;
    while (true) {
      final page = await loadPage(limit: pageSize, beforeServerTsMs: cursor);
      all.addAll(page);
      if (page.length < pageSize) break;
      cursor = page.first.serverTs.millisecondsSinceEpoch;
    }
    return classify(all);
  }

  /// Splits [messages] into media / links / files, newest first.
  SharedContent classify(List<ChatMessage> messages) {
    final now = _now();
    final live = messages.where((m) {
      if (m.failed || m.uploading) return false;
      final exp = m.expiresAt;
      return exp == null || exp.isAfter(now);
    }).toList()
      ..sort((a, b) => b.serverTs.compareTo(a.serverTs));

    final media = <ChatMessage>[];
    final files = <ChatMessage>[];
    final links = <SharedLink>[];
    for (final m in live) {
      switch (m.kind) {
        case MessageKind.image:
          if (!_isGifOrSticker(m)) media.add(m);
        case MessageKind.video:
          media.add(m);
        case MessageKind.file:
          files.add(m);
        case MessageKind.voice:
        case MessageKind.system:
          continue;
        case MessageKind.text:
          break;
      }
      // Links live in text bodies and in media captions.
      if (m.kind != MessageKind.system && m.body.isNotEmpty) {
        for (final url in extractLinks(m.body)) {
          links.add(SharedLink(url: url, message: m));
        }
      }
    }
    return SharedContent(media: media, links: links, files: files);
  }

  static bool _isGifOrSticker(ChatMessage m) =>
      StickerMarker.isSticker(m) || m.mediaMime == 'image/gif';

  /// URLs in [text], trailing sentence punctuation trimmed.
  static List<String> extractLinks(String text) {
    return [
      for (final match in _url.allMatches(text))
        match.group(0)!.replaceAll(RegExp(r'[.,;:!?)\]]+$'), ''),
    ].where((u) => u.isNotEmpty).toList();
  }
}
