import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/core/models/incoming_share.dart';
import 'package:nanb_chat/core/models/shared_attachment.dart';
import 'package:nanb_chat/features/chat/models/chat_message.dart';
import 'package:nanb_chat/features/chat/services/share_dispatcher.dart';
import 'package:nanb_chat/features/chat/services/share_send_target.dart';

/// Records which send path a share took, standing in for the notifier.
class _FakeTarget implements ShareSendTarget {
  final List<String> texts = [];
  final List<({List<int> bytes, String mime, String caption})> images = [];
  final List<({List<int> bytes, String mime, String caption})> videos = [];
  final List<({List<int> bytes, String mime, String filename})> files = [];

  @override
  Future<void> sendMessage({
    required String conversationId,
    required String myDeviceId,
    required String text,
    ChatMessage? replyTo,
  }) async {
    texts.add(text);
  }

  @override
  Future<void> sendImage({
    required String conversationId,
    required String myDeviceId,
    required List<int> imageBytes,
    required String mimeType,
    String caption = '',
    bool forwarded = false,
  }) async {
    images.add((bytes: imageBytes, mime: mimeType, caption: caption));
  }

  @override
  Future<void> sendVideo({
    required String conversationId,
    required String myDeviceId,
    required List<int> videoBytes,
    required String mimeType,
    String caption = '',
    bool forwarded = false,
  }) async {
    videos.add((bytes: videoBytes, mime: mimeType, caption: caption));
  }

  @override
  Future<void> sendFile({
    required String conversationId,
    required String myDeviceId,
    required List<int> fileBytes,
    required String mimeType,
    required String filename,
    bool forwarded = false,
  }) async {
    files.add((bytes: fileBytes, mime: mimeType, filename: filename));
  }
}

SharedAttachment _attachment({
  String path = '/cache/a.jpg',
  String mime = 'image/jpeg',
  String name = 'a.jpg',
}) =>
    SharedAttachment(path: path, mimeType: mime, filename: name);

void main() {
  late _FakeTarget target;

  /// Dispatcher whose file loader serves fixed bytes per path, so the tests
  /// never touch the disk. A path absent from [bytes] loads as unreadable.
  ShareDispatcher dispatcherFor(Map<String, List<int>> bytes) =>
      ShareDispatcher(target, loadFile: (path) async => bytes[path]);

  Future<int> deliver(ShareDispatcher dispatcher, IncomingShare share) =>
      dispatcher.deliver(
        share: share,
        conversationId: 'c1',
        myDeviceId: 'dev-1',
      );

  setUp(() => target = _FakeTarget());

  group('deliverToAll', () {
    test('sends shared text once per recipient', () async {
      await dispatcherFor(const {}).deliverToAll(
        share: const IncomingShare(text: 'https://nanb.us'),
        conversationIds: const ['c1', 'c2', 'c3'],
        myDeviceId: 'dev-1',
      );
      expect(target.texts, hasLength(3));
    });

    test('reads a shared file only once however many recipients', () async {
      var loads = 0;
      final dispatcher = ShareDispatcher(target, loadFile: (path) async {
        loads++;
        return const [1, 2, 3];
      });
      await dispatcher.deliverToAll(
        share: IncomingShare(attachments: [_attachment()]),
        conversationIds: const ['c1', 'c2'],
        myDeviceId: 'dev-1',
      );
      expect(loads, 1);
    });

    test('delivers the same file bytes to every recipient', () async {
      await dispatcherFor({'/cache/a.jpg': const [1, 2, 3]}).deliverToAll(
        share: IncomingShare(attachments: [_attachment()]),
        conversationIds: const ['c1', 'c2'],
        myDeviceId: 'dev-1',
      );
      expect(target.images.map((i) => i.bytes), [
        const [1, 2, 3],
        const [1, 2, 3],
      ]);
    });

    test('reports the number sent per conversation', () async {
      final sent = await dispatcherFor(const {}).deliverToAll(
        share: const IncomingShare(text: 'hi'),
        conversationIds: const ['c1', 'c2'],
        myDeviceId: 'dev-1',
      );
      expect(sent, {'c1': 1, 'c2': 1});
    });
  });

  test('sends shared text as a text message', () async {
    await deliver(
      dispatcherFor(const {}),
      const IncomingShare(text: 'https://nanb.us'),
    );
    expect(target.texts, ['https://nanb.us']);
  });

  test('sends a shared photo down the image path', () async {
    await deliver(
      dispatcherFor({'/cache/a.jpg': const [1, 2, 3]}),
      IncomingShare(attachments: [_attachment()]),
    );
    expect(target.images.single.bytes, const [1, 2, 3]);
    expect(target.images.single.mime, 'image/jpeg');
  });

  test('sends a shared clip down the video path', () async {
    await deliver(
      dispatcherFor({'/cache/v.mp4': const [9]}),
      IncomingShare(attachments: [
        _attachment(path: '/cache/v.mp4', mime: 'video/mp4', name: 'v.mp4'),
      ]),
    );
    expect(target.videos.single.mime, 'video/mp4');
  });

  test('sends a shared document down the file path', () async {
    await deliver(
      dispatcherFor({'/cache/spec.pdf': const [7]}),
      IncomingShare(attachments: [
        _attachment(
            path: '/cache/spec.pdf', mime: 'application/pdf', name: 'spec.pdf'),
      ]),
    );
    expect(target.files.single.mime, 'application/pdf');
  });

  test('preserves the original filename on a shared document', () async {
    await deliver(
      dispatcherFor({'/cache/spec.pdf': const [7]}),
      IncomingShare(attachments: [
        _attachment(
            path: '/cache/spec.pdf', mime: 'application/pdf', name: 'Q3 plan.pdf'),
      ]),
    );
    expect(target.files.single.filename, 'Q3 plan.pdf');
  });

  test('sends a shared audio file as a file, not a voice note', () async {
    await deliver(
      dispatcherFor({'/cache/song.m4a': const [4]}),
      IncomingShare(attachments: [
        _attachment(path: '/cache/song.m4a', mime: 'audio/mp4', name: 'song.m4a'),
      ]),
    );
    expect(target.files, hasLength(1));
  });

  test('folds text into the caption of a lone shared photo', () async {
    await deliver(
      dispatcherFor({'/cache/a.jpg': const [1]}),
      IncomingShare(text: 'look at this', attachments: [_attachment()]),
    );
    expect(target.images.single.caption, 'look at this');
    expect(target.texts, isEmpty);
  });

  test('sends text separately when it accompanies a document', () async {
    await deliver(
      dispatcherFor({'/cache/spec.pdf': const [7]}),
      IncomingShare(text: 'the spec', attachments: [
        _attachment(
            path: '/cache/spec.pdf', mime: 'application/pdf', name: 'spec.pdf'),
      ]),
    );
    expect(target.texts, ['the spec']);
    expect(target.files, hasLength(1));
  });

  test('sends text separately when several photos are shared', () async {
    await deliver(
      dispatcherFor({'/cache/a.jpg': const [1], '/cache/b.jpg': const [2]}),
      IncomingShare(text: 'holiday', attachments: [
        _attachment(),
        _attachment(path: '/cache/b.jpg', name: 'b.jpg'),
      ]),
    );
    expect(target.texts, ['holiday']);
    expect(target.images.map((i) => i.caption), ['', '']);
  });

  test('reports how many messages were sent', () async {
    final sent = await deliver(
      dispatcherFor({'/cache/a.jpg': const [1], '/cache/b.jpg': const [2]}),
      IncomingShare(text: 'holiday', attachments: [
        _attachment(),
        _attachment(path: '/cache/b.jpg', name: 'b.jpg'),
      ]),
    );
    expect(sent, 3);
  });

  test('skips an attachment whose bytes cannot be loaded', () async {
    await deliver(
      dispatcherFor(const {}),
      IncomingShare(attachments: [_attachment()]),
    );
    expect(target.images, isEmpty);
  });

  test('still sends the readable attachments when one fails to load', () async {
    final sent = await deliver(
      dispatcherFor({'/cache/b.jpg': const [2]}),
      IncomingShare(attachments: [
        _attachment(),
        _attachment(path: '/cache/b.jpg', name: 'b.jpg'),
      ]),
    );
    expect(sent, 1);
    expect(target.images, hasLength(1));
  });

  test('treats an empty file as unsendable', () async {
    final sent = await deliver(
      dispatcherFor({'/cache/a.jpg': const []}),
      IncomingShare(attachments: [_attachment()]),
    );
    expect(sent, 0);
  });
}
