import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/features/chat/models/forward_marker.dart';
import 'package:nanb_chat/features/chat/models/message_control.dart';
import 'package:nanb_chat/features/chat/models/privacy_header.dart';
import 'package:nanb_chat/features/chat/models/reply_ref.dart';

void main() {
  group('PrivacyHeader', () {
    test('encode prefix + split round-trips both flags', () {
      for (final (s, f) in const [(true, false), (false, true), (true, true)]) {
        final header =
            PrivacyHeader(blocksScreenshots: s, blocksForwarding: f);
        final wire = '${header.encodePrefix()}the message';
        final split = PrivacyHeader.split(wire);
        expect(split, isNotNull);
        final (parsed, body) = split!;
        expect(parsed.blocksScreenshots, s);
        expect(parsed.blocksForwarding, f);
        expect(body, 'the message');
      }
    });

    test('split returns null for plain / reply / forward bodies', () {
      expect(PrivacyHeader.split('just a normal message'), isNull);
      expect(PrivacyHeader.split(''), isNull);
      expect(PrivacyHeader.split('{"_reply":{"id":"x"}}\nbody'), isNull);
      expect(PrivacyHeader.split('${ForwardMarker.prefix}body'), isNull);
    });

    test('split rejects malformed headers gracefully', () {
      expect(PrivacyHeader.split('{"_priv": not json}\nbody'), isNull);
      expect(PrivacyHeader.split('{"_priv":{"s":"yes","f":0}}\nbody'), isNull);
    });

    test('header stacking: privacy → reply → forward splits in order', () {
      // The sender's composition order in _submitOutbox/_sendOptimistic:
      // privacy header outermost, then reply, then the forward marker.
      const priv =
          PrivacyHeader(blocksScreenshots: true, blocksForwarding: true);
      const ref = ReplyRef(envelopeId: 'e1', sender: '@a', preview: 'p');
      final wire = '${priv.encodePrefix()}${ref.encodePrefix()}'
          '${ForwardMarker.prefix}actual text';

      final (p, afterPriv) = PrivacyHeader.split(wire)!;
      expect(p.blocksScreenshots, isTrue);
      final (r, afterReply) = ReplyRef.split(afterPriv)!;
      expect(r.envelopeId, 'e1');
      expect(ForwardMarker.split(afterReply), 'actual text');
    });
  });

  group('MessageControl.privacy', () {
    test('encode + tryDecode round-trips the flags', () {
      final encoded =
          const MessageControl.privacy(screenshots: true, forwarding: false)
              .encode();
      final decoded = MessageControl.tryDecode(encoded);
      expect(decoded, isNotNull);
      expect(decoded!.isPrivacy, isTrue);
      expect(decoded.privacyScreenshots, isTrue);
      expect(decoded.privacyForwarding, isFalse);
      expect(decoded.isReceipt, isFalse);
      expect(decoded.isRequestDecision, isFalse);
    });

    test('tryDecode rejects non-bool flags', () {
      expect(
        MessageControl.tryDecode(
            '{"_control":"privacy","screenshots":1,"forwarding":false}'),
        isNull,
      );
      expect(
        MessageControl.tryDecode('{"_control":"privacy","screenshots":true}'),
        isNull,
      );
    });

    test('a privacy header body is NOT a control', () {
      const header =
          PrivacyHeader(blocksScreenshots: true, blocksForwarding: true);
      expect(
        MessageControl.tryDecode('${header.encodePrefix()}text'),
        isNull,
      );
    });
  });

  group('MessageControl.reestablish', () {
    test('encode + tryDecode round-trips as a no-op control', () {
      final decoded =
          MessageControl.tryDecode(const MessageControl.reestablish().encode());
      expect(decoded, isNotNull);
      expect(decoded!.isReestablish, isTrue);
      expect(decoded.isReceipt, isFalse);
      expect(decoded.isRequestDecision, isFalse);
      expect(decoded.isPrivacy, isFalse);
    });
  });
}
