import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/features/chat/contact_link_payload.dart';

void main() {
  final key = List<int>.generate(32, (i) => i);

  group('ContactLinkPayload', () {
    test('encode/parse round-trips', () {
      final encoded =
          ContactLinkPayload(username: 'bob6', publicKey: key).encode();
      final parsed = ContactLinkPayload.parse(encoded);
      expect(parsed.username, 'bob6');
      expect(parsed.publicKey, key);
    });

    test('encode escapes username query chars', () {
      final encoded =
          ContactLinkPayload(username: 'a_b-c', publicKey: key).encode();
      expect(ContactLinkPayload.parse(encoded).username, 'a_b-c');
    });

    test('fingerprint is first 6 bytes as 3 hex groups', () {
      final p = ContactLinkPayload(username: 'x', publicKey: key);
      expect(p.fingerprint, '0001 0203 0405');
    });

    test('parse rejects wrong scheme', () {
      expect(
        () => ContactLinkPayload.parse('https://contact?u=a&pk=00'),
        throwsFormatException,
      );
    });

    test('parse rejects wrong host (device payloads)', () {
      expect(
        () => ContactLinkPayload.parse('nanb-link://device?id=a&pk=00'),
        throwsFormatException,
      );
    });

    test('parse rejects missing username', () {
      final hex = key.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      expect(
        () => ContactLinkPayload.parse('nanb-link://contact?pk=$hex'),
        throwsFormatException,
      );
    });

    test('parse rejects short key', () {
      expect(
        () => ContactLinkPayload.parse('nanb-link://contact?u=a&pk=0001'),
        throwsFormatException,
      );
    });

    test('parse rejects non-hex key', () {
      expect(
        () => ContactLinkPayload.parse('nanb-link://contact?u=a&pk=zz'),
        throwsFormatException,
      );
    });
  });
}
