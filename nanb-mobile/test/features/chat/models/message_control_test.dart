import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/features/chat/models/link_preview.dart';
import 'package:nanb_chat/features/chat/models/message_control.dart';

void main() {
  group('MessageControl', () {
    test('encode/decode round-trips an unsend', () {
      final encoded = const MessageControl.unsend('env-123').encode();
      final decoded = MessageControl.tryDecode(encoded);
      expect(decoded, isNotNull);
      expect(decoded!.targetEnvelopeId, 'env-123');
    });

    test('plain text is not a control payload', () {
      expect(MessageControl.tryDecode('hello there'), isNull);
      expect(MessageControl.tryDecode(''), isNull);
    });

    test('encode/decode round-trips an access-key (UAK) control', () {
      final uak = List<int>.generate(32, (i) => i * 7 % 256);
      final encoded = MessageControl.accessKey(uak).encode();
      final decoded = MessageControl.tryDecode(encoded);
      expect(decoded, isNotNull);
      expect(decoded!.isAccessKey, isTrue);
      expect(decoded.accessKey, equals(uak));
      // It must not be mistaken for any other control kind.
      expect(decoded.isReceipt, isFalse);
      expect(decoded.isPrivacy, isFalse);
      expect(decoded.isRequestDecision, isFalse);
    });

    test('an access-key control with a bad/empty uak decodes to null', () {
      expect(MessageControl.tryDecode('{"_control":"access_key"}'), isNull);
      expect(
          MessageControl.tryDecode('{"_control":"access_key","uak":""}'), isNull);
      expect(
          MessageControl.tryDecode('{"_control":"access_key","uak":"!not b64!"}'),
          isNull);
    });

    test('a system-event JSON body is not an unsend control', () {
      // _system events are a different JSON shape; must not be mistaken for one.
      expect(
        MessageControl.tryDecode('{"_system":"member_joined"}'),
        isNull,
      );
    });

    test('malformed / partial JSON returns null instead of throwing', () {
      expect(MessageControl.tryDecode('{"_control":'), isNull);
      expect(MessageControl.tryDecode('{"_control":"unsend"}'), isNull); // no target
      expect(MessageControl.tryDecode('{"_control":"unsend","target":""}'), isNull);
      expect(MessageControl.tryDecode('{"_control":"other","target":"x"}'), isNull);
    });

    test('encode/decode round-trips a delivered receipt', () {
      final encoded =
          const MessageControl.receipt(ReceiptKind.delivered, ['a', 'b'])
              .encode();
      final decoded = MessageControl.tryDecode(encoded);
      expect(decoded, isNotNull);
      expect(decoded!.isReceipt, isTrue);
      expect(decoded.receiptKind, ReceiptKind.delivered);
      expect(decoded.receiptIds, ['a', 'b']);
    });

    test('encode/decode round-trips a read receipt', () {
      final decoded = MessageControl.tryDecode(
          const MessageControl.receipt(ReceiptKind.read, ['x']).encode());
      expect(decoded!.receiptKind, ReceiptKind.read);
      expect(decoded.receiptIds, ['x']);
    });

    test('an unsend is not a receipt', () {
      expect(const MessageControl.unsend('e').isReceipt, isFalse);
    });

    test('encode/decode round-trips a reaction (set)', () {
      final decoded = MessageControl.tryDecode(
        const MessageControl.reaction(targetEnvelopeId: 'env-9', emoji: '👍')
            .encode(),
      );
      expect(decoded, isNotNull);
      expect(decoded!.isReaction, isTrue);
      expect(decoded.targetEnvelopeId, 'env-9');
      expect(decoded.reactionEmoji, '👍');
      expect(decoded.reactionRemove, isFalse);
      // Not mistaken for an unsend (which also carries a target).
      expect(decoded.isReceipt, isFalse);
    });

    test('encode/decode round-trips a reaction removal', () {
      final decoded = MessageControl.tryDecode(
        const MessageControl.reaction(
                targetEnvelopeId: 'env-9', emoji: '❤️', remove: true)
            .encode(),
      );
      expect(decoded!.isReaction, isTrue);
      expect(decoded.reactionRemove, isTrue);
      expect(decoded.reactionEmoji, '❤️');
    });

    test('encode/decode round-trips a pin (set)', () {
      final decoded = MessageControl.tryDecode(
        const MessageControl.pin(targetEnvelopeId: 'env-9').encode(),
      );
      expect(decoded, isNotNull);
      expect(decoded!.isPin, isTrue);
      expect(decoded.targetEnvelopeId, 'env-9');
      expect(decoded.pinRemove, isFalse);
      // A pin carries only a target, like unsend/reaction — must not be
      // mistaken for either.
      expect(decoded.isReaction, isFalse);
      expect(decoded.isReceipt, isFalse);
    });

    test('encode/decode round-trips a pin removal', () {
      final decoded = MessageControl.tryDecode(
        const MessageControl.pin(targetEnvelopeId: 'env-9', remove: true)
            .encode(),
      );
      expect(decoded!.isPin, isTrue);
      expect(decoded.pinRemove, isTrue);
      expect(decoded.targetEnvelopeId, 'env-9');
    });

    test('a pin set with an empty target is rejected; a clear is allowed', () {
      expect(
        MessageControl.tryDecode('{"_control":"pin","target":""}'),
        isNull, // a set must name a message
      );
      final clear = MessageControl.tryDecode(
          '{"_control":"pin","target":"","remove":true}');
      expect(clear, isNotNull);
      expect(clear!.isPin, isTrue);
      expect(clear.pinRemove, isTrue);
    });

    test('malformed reactions return null', () {
      expect(MessageControl.tryDecode('{"_control":"reaction"}'), isNull);
      expect(
        MessageControl.tryDecode('{"_control":"reaction","target":"e"}'),
        isNull, // no emoji
      );
      expect(
        MessageControl.tryDecode('{"_control":"reaction","emoji":"👍"}'),
        isNull, // no target
      );
      expect(
        MessageControl.tryDecode(
            '{"_control":"reaction","target":"","emoji":"👍"}'),
        isNull,
      );
    });

    test('encode/decode round-trips a screenshot control', () {
      final decoded = MessageControl.tryDecode(
        const MessageControl.screenshot().encode(),
      );
      expect(decoded, isNotNull);
      expect(decoded!.isScreenshot, isTrue);
      // It carries no target/payload and must not look like any other control.
      expect(decoded.targetEnvelopeId, isEmpty);
      expect(decoded.isReceipt, isFalse);
      expect(decoded.isPrivacy, isFalse);
      expect(decoded.isPin, isFalse);
      expect(decoded.isReaction, isFalse);
      expect(decoded.isAccessKey, isFalse);
    });

    test('encode/decode round-trips a link preview control', () {
      const preview = LinkPreview(
        url: 'https://example.com/a',
        title: 'A page',
        description: 'About it',
        thumbnail: [1, 2, 3],
      );
      final decoded = MessageControl.tryDecode(
        const MessageControl.linkPreview(
                targetEnvelopeId: 'env-9', preview: preview)
            .encode(),
      );

      expect(decoded!.isLinkPreview, isTrue);
      expect(decoded.targetEnvelopeId, 'env-9');
      expect(decoded.linkPreview, preview);
    });

    test('a link preview control is not mistaken for another control', () {
      final decoded = MessageControl.tryDecode(
        const MessageControl.linkPreview(
          targetEnvelopeId: 'env-9',
          preview: LinkPreview(url: 'https://e.com', title: 't'),
        ).encode(),
      );

      expect(decoded!.isPin, isFalse);
      expect(decoded.isReaction, isFalse);
      expect(decoded.isScreenshot, isFalse);
    });

    test('a link preview control with no target is rejected', () {
      expect(
        MessageControl.tryDecode(
            '{"_control":"link_preview","target":"","preview":{"url":"https://e.com","title":"t"}}'),
        isNull,
      );
    });

    test('a link preview control with no title is rejected', () {
      expect(
        MessageControl.tryDecode(
            '{"_control":"link_preview","target":"e","preview":{"url":"https://e.com"}}'),
        isNull,
      );
    });

    test('an unsend / pin is not a screenshot control', () {
      expect(const MessageControl.unsend('e').isScreenshot, isFalse);
      expect(
        const MessageControl.pin(targetEnvelopeId: 'e').isScreenshot,
        isFalse,
      );
    });

    test('malformed receipts return null', () {
      expect(MessageControl.tryDecode('{"_control":"receipt"}'), isNull); // no kind/ids
      expect(
        MessageControl.tryDecode('{"_control":"receipt","kind":"bogus","ids":["a"]}'),
        isNull,
      );
      expect(
        MessageControl.tryDecode('{"_control":"receipt","kind":"read","ids":[]}'),
        isNull, // empty id list
      );
    });
  });
}
