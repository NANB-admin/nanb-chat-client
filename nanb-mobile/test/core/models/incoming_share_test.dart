import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/core/models/incoming_share.dart';

/// The platform channel hands back a `Map<Object?, Object?>` with a
/// `List<Object?>` of attachment maps — mirror that shape exactly, since a
/// convenient `Map<String, String>` in the test would hide a real cast bug.
Map<Object?, Object?> _payload({
  Object? text,
  List<Object?>? attachments,
}) {
  final payload = <Object?, Object?>{};
  if (text != null) payload['text'] = text;
  if (attachments != null) payload['attachments'] = attachments;
  return payload;
}

/// A null argument means the key is ABSENT from the map — which is how the
/// native side reports a stream it couldn't copy or a type it couldn't
/// determine.
Map<Object?, Object?> _attachment({
  Object? path = '/tmp/a.jpg',
  Object? name = 'a.jpg',
  Object? mime = 'image/jpeg',
}) {
  final attachment = <Object?, Object?>{};
  if (path != null) attachment['path'] = path;
  if (name != null) attachment['name'] = name;
  if (mime != null) attachment['mime'] = mime;
  return attachment;
}

void main() {
  group('IncomingShare.tryParse', () {
    test('returns null when nothing is pending', () {
      expect(IncomingShare.tryParse(null), isNull);
    });

    test('returns null for a payload carrying neither text nor attachments', () {
      expect(IncomingShare.tryParse(_payload(text: '', attachments: <Object?>[])),
          isNull);
    });

    test('reads shared text', () {
      final share = IncomingShare.tryParse(_payload(text: 'https://nanb.us'));
      expect(share?.text, 'https://nanb.us');
    });

    test('trims surrounding whitespace off shared text', () {
      final share = IncomingShare.tryParse(_payload(text: '  hello  '));
      expect(share?.text, 'hello');
    });

    test('reads an attachment', () {
      final share = IncomingShare.tryParse(_payload(
        attachments: <Object?>[
          _attachment(path: '/cache/photo.png', name: 'photo.png', mime: 'image/png'),
        ],
      ));
      expect(share?.attachments.single.path, '/cache/photo.png');
      expect(share?.attachments.single.filename, 'photo.png');
      expect(share?.attachments.single.mimeType, 'image/png');
    });

    test('skips an attachment the native side could not copy', () {
      final share = IncomingShare.tryParse(_payload(
        attachments: <Object?>[_attachment(path: null), _attachment()],
      ));
      expect(share?.attachments, hasLength(1));
    });

    test('falls back to a generic MIME type when the OS reported none', () {
      final share = IncomingShare.tryParse(
          _payload(attachments: <Object?>[_attachment(mime: null)]));
      expect(share?.attachments.single.mimeType, 'application/octet-stream');
    });

    test('ignores a non-map entry in the attachments list', () {
      final share = IncomingShare.tryParse(
          _payload(text: 'hi', attachments: <Object?>['not-a-map']));
      expect(share?.attachments, isEmpty);
    });
  });

  group('IncomingShare.messageCount', () {
    test('counts text alone as one message', () {
      const share = IncomingShare(text: 'hi');
      expect(share.messageCount, 1);
    });

    test('counts each attachment', () {
      final share = IncomingShare.tryParse(_payload(
        attachments: <Object?>[_attachment(), _attachment(path: '/tmp/b.jpg')],
      ));
      expect(share?.messageCount, 2);
    });

    test('does not count text riding along as a lone photo caption', () {
      final share = IncomingShare.tryParse(
          _payload(text: 'look', attachments: <Object?>[_attachment()]));
      expect(share?.messageCount, 1);
    });

    test('counts text separately alongside a lone document', () {
      final share = IncomingShare.tryParse(_payload(
        text: 'the spec',
        attachments: <Object?>[_attachment(mime: 'application/pdf')],
      ));
      expect(share?.messageCount, 2);
    });

    test('counts text separately alongside multiple photos', () {
      final share = IncomingShare.tryParse(_payload(
        text: 'holiday',
        attachments: <Object?>[_attachment(), _attachment(path: '/tmp/b.jpg')],
      ));
      expect(share?.messageCount, 3);
    });
  });
}
