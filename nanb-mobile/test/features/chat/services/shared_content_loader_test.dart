import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/features/chat/models/chat_message.dart';
import 'package:nanb_chat/features/chat/models/message_kind.dart';
import 'package:nanb_chat/features/chat/services/shared_content_loader.dart';

final _now = DateTime.utc(2026, 11, 3, 12);

ChatMessage _msg(
  String id, {
  MessageKind kind = MessageKind.text,
  String body = '',
  String? mime,
  String? filename,
  int minutesAgo = 0,
  DateTime? expiresAt,
  bool failed = false,
}) =>
    ChatMessage(
      envelopeId: id,
      conversationId: 'c1',
      senderDeviceId: 'd1',
      body: body,
      serverTs: _now.subtract(Duration(minutes: minutesAgo)),
      mine: false,
      kind: kind,
      mediaMime: mime,
      mediaFilename: filename,
      expiresAt: expiresAt,
      failed: failed,
    );

void main() {
  final loader = SharedContentLoader(now: () => _now);

  test('photos and videos are listed as media', () {
    final c = loader.classify([
      _msg('a', kind: MessageKind.image, mime: 'image/jpeg'),
      _msg('b', kind: MessageKind.video, mime: 'video/mp4'),
    ]);
    expect(c.media.map((m) => m.envelopeId), unorderedEquals(['a', 'b']));
  });

  test('a GIF is not listed as media', () {
    final c = loader.classify([
      _msg('g', kind: MessageKind.image, mime: 'image/gif'),
    ]);
    expect(c.media, isEmpty);
  });

  test('a sticker is not listed as media', () {
    final c = loader.classify([
      _msg('s',
          kind: MessageKind.image, mime: 'image/webp', filename: 'sticker.webp'),
    ]);
    expect(c.media, isEmpty);
  });

  test('files are listed under files', () {
    final c = loader.classify([
      _msg('f', kind: MessageKind.file, filename: 'a.pdf'),
    ]);
    expect(c.files.single.envelopeId, 'f');
  });

  test('a link in a text message is listed', () {
    final c = loader.classify([_msg('t', body: 'see https://nanb.us/x ok')]);
    expect(c.links.single.url, 'https://nanb.us/x');
  });

  test('trailing punctuation is trimmed from a link', () {
    final c = loader.classify([_msg('t', body: 'go to https://nanb.us.')]);
    expect(c.links.single.url, 'https://nanb.us');
  });

  test('a www link without a scheme is found', () {
    final c = loader.classify([_msg('t', body: 'www.example.com/a')]);
    expect(c.links.single.url, 'www.example.com/a');
  });

  test('a link in a media caption is listed', () {
    final c = loader.classify([
      _msg('i',
          kind: MessageKind.image,
          mime: 'image/jpeg',
          body: 'look https://nanb.us'),
    ]);
    expect(c.links, hasLength(1));
  });

  test('text without a link adds nothing to links', () {
    final c = loader.classify([_msg('t', body: 'hello there')]);
    expect(c.links, isEmpty);
  });

  test('an expired message is excluded', () {
    final c = loader.classify([
      _msg('e',
          kind: MessageKind.image,
          mime: 'image/jpeg',
          expiresAt: _now.subtract(const Duration(minutes: 1))),
    ]);
    expect(c.media, isEmpty);
  });

  test('a not-yet-expired message is kept', () {
    final c = loader.classify([
      _msg('e',
          kind: MessageKind.image,
          mime: 'image/jpeg',
          expiresAt: _now.add(const Duration(hours: 1))),
    ]);
    expect(c.media, hasLength(1));
  });

  test('a failed send is excluded', () {
    final c = loader.classify([
      _msg('x', kind: MessageKind.file, filename: 'a', failed: true),
    ]);
    expect(c.files, isEmpty);
  });

  test('results are newest first', () {
    final c = loader.classify([
      _msg('old', kind: MessageKind.file, filename: 'a', minutesAgo: 30),
      _msg('new', kind: MessageKind.file, filename: 'b', minutesAgo: 1),
    ]);
    expect(c.files.map((m) => m.envelopeId), ['new', 'old']);
  });

  test('load pages through the whole history', () async {
    final paged = SharedContentLoader(pageSize: 2, now: () => _now);
    final all = [
      for (var i = 0; i < 5; i++)
        _msg('m$i',
            kind: MessageKind.file, filename: 'f$i', minutesAgo: 50 - i),
    ];
    final c = await paged.load(({required limit, beforeServerTsMs}) async {
      final eligible = all
          .where((m) =>
              beforeServerTsMs == null ||
              m.serverTs.millisecondsSinceEpoch < beforeServerTsMs)
          .toList()
        ..sort((a, b) => a.serverTs.compareTo(b.serverTs));
      return eligible.sublist(eligible.length > limit ? eligible.length - limit : 0);
    });
    expect(c.files, hasLength(5));
  });
}
