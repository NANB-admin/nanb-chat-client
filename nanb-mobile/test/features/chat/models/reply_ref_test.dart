import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/features/chat/models/reply_ref.dart';

void main() {
  group('ReplyRef', () {
    test('encode prefix + split round-trips the ref and preserves the body', () {
      const ref = ReplyRef(
        envelopeId: 'env-42',
        sender: '@cara1',
        preview: 'the original message',
      );
      final wire = '${ref.encodePrefix()}my reply body';

      final split = ReplyRef.split(wire);
      expect(split, isNotNull);
      final (parsed, body) = split!;
      expect(parsed.envelopeId, 'env-42');
      expect(parsed.sender, '@cara1');
      expect(parsed.preview, 'the original message');
      expect(body, 'my reply body');
    });

    test('split returns null for a plain (non-reply) body', () {
      expect(ReplyRef.split('just a normal message'), isNull);
      expect(ReplyRef.split('{"k":"image","mid":"x"}'), isNull);
      expect(ReplyRef.split(''), isNull);
    });

    test('split tolerates a body containing newlines after the header', () {
      const ref =
          ReplyRef(envelopeId: 'e', sender: 's', preview: 'p');
      final wire = '${ref.encodePrefix()}line one\nline two';
      final (_, body) = ReplyRef.split(wire)!;
      expect(body, 'line one\nline two');
    });

    test('split rejects a malformed reply header gracefully', () {
      // Looks like a reply prefix but the JSON is broken.
      expect(ReplyRef.split('{"_reply": not json}\nbody'), isNull);
      // Missing required fields.
      expect(ReplyRef.split('{"_reply":{"id":"x"}}\nbody'), isNull);
    });
  });
}
