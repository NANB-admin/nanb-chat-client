import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/features/chat/models/ttl_header.dart';

void main() {
  group('TtlHeader', () {
    test('encode then split round-trips and preserves the remaining body', () {
      final wire = TtlHeader(300).encodePrefix() + 'hello world';
      final split = TtlHeader.split(wire);
      expect(split, isNotNull);
      expect(split!.$1.ttlSeconds, 300);
      expect(split.$2, 'hello world');
    });

    test('split returns null for a body without the header', () {
      expect(TtlHeader.split('plain text'), isNull);
      expect(TtlHeader.split('{"_priv":{"s":1,"f":0}}\nbody'), isNull);
    });

    test('split rejects non-positive or non-int ttl', () {
      expect(TtlHeader.split('{"_ttl":0}\nbody'), isNull);
      expect(TtlHeader.split('{"_ttl":-5}\nbody'), isNull);
      expect(TtlHeader.split('{"_ttl":"x"}\nbody'), isNull);
    });

    test('split rejects a header line with no newline', () {
      expect(TtlHeader.split('{"_ttl":300}'), isNull);
    });

    test('an empty remaining body is preserved', () {
      final split = TtlHeader.split(TtlHeader(60).encodePrefix());
      expect(split, isNotNull);
      expect(split!.$1.ttlSeconds, 60);
      expect(split.$2, '');
    });
  });
}
