import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/features/chat/models/forward_marker.dart';
import 'package:nanb_chat/features/chat/models/message_control.dart';

void main() {
  group('ForwardMarker', () {
    test('prefix + split round-trips the body', () {
      final wire = '${ForwardMarker.prefix}hello there';
      expect(ForwardMarker.split(wire), 'hello there');
    });

    test('split returns null for a plain body', () {
      expect(ForwardMarker.split('just a normal message'), isNull);
      expect(ForwardMarker.split(''), isNull);
      // A reply header is not a forward marker.
      expect(ForwardMarker.split('{"_reply":{"id":"x"}}\nbody'), isNull);
    });

    test('split preserves newlines + a media descriptor body', () {
      final wire = '${ForwardMarker.prefix}{"k":"image","mid":"x"}\ncaption';
      expect(ForwardMarker.split(wire), '{"k":"image","mid":"x"}\ncaption');
    });

    test('the marker itself is not mistaken for a control payload', () {
      // The full wire body (marker + text) must not decode as a control —
      // the receiver checks controls AFTER splitting headers, but a
      // malformed split must not turn a forwarded message into a control.
      expect(MessageControl.tryDecode('${ForwardMarker.prefix}hi'), isNull);
    });
  });
}
