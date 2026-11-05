import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/core/push/call_launch_payload.dart';

void main() {
  group('CallLaunchPayload', () {
    test('encode → decode round-trips the conversation + caller', () {
      final s = CallLaunchPayload.encode('1to1:a:b', '@alice');
      final p = CallLaunchPayload.decode(s)!;
      expect(p.conversationId, '1to1:a:b');
      expect(p.caller, '@alice');
    });

    test('a bare conversationId (message deep-link) decodes to null', () {
      // Ordinary message notifications attach the raw conversation id; those
      // must NOT be mistaken for a call launch.
      expect(CallLaunchPayload.decode('1to1:a:b'), isNull);
      expect(CallLaunchPayload.decode('group:xyz'), isNull);
    });

    test('null / empty / non-call JSON decode to null', () {
      expect(CallLaunchPayload.decode(null), isNull);
      expect(CallLaunchPayload.decode(''), isNull);
      expect(CallLaunchPayload.decode('{"k":"other","c":"x"}'), isNull);
      expect(CallLaunchPayload.decode('{"k":"call"}'), isNull); // no convo id
    });

    test('a missing caller name decodes to an empty string', () {
      final p = CallLaunchPayload.decode('{"k":"call","c":"1to1:a:b"}')!;
      expect(p.conversationId, '1to1:a:b');
      expect(p.caller, '');
    });
  });
}
