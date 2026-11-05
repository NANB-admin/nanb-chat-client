import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/features/chat/models/client_msg_id_header.dart';

void main() {
  group('ClientMsgIdHeader', () {
    test('encode then split round-trips and preserves the remaining body', () {
      final wire = '${ClientMsgIdHeader('outbox-42').encodePrefix()}hello world';
      final split = ClientMsgIdHeader.split(wire);
      expect(split, isNotNull);
      expect(split!.$1.id, 'outbox-42');
      expect(split.$2, 'hello world');
    });

    test('split returns null for a body without the header', () {
      expect(ClientMsgIdHeader.split('plain text'), isNull);
      expect(ClientMsgIdHeader.split('{"_ttl":300}\nbody'), isNull);
    });

    test('split rejects an empty or non-string id', () {
      expect(ClientMsgIdHeader.split('{"_cid":""}\nbody'), isNull);
      expect(ClientMsgIdHeader.split('{"_cid":7}\nbody'), isNull);
    });

    test('split rejects a header line with no newline', () {
      expect(ClientMsgIdHeader.split('{"_cid":"outbox-1"}'), isNull);
    });

    test('an empty remaining body is preserved', () {
      final split =
          ClientMsgIdHeader.split(ClientMsgIdHeader('outbox-9').encodePrefix());
      expect(split, isNotNull);
      expect(split!.$1.id, 'outbox-9');
      expect(split.$2, '');
    });
  });
}
