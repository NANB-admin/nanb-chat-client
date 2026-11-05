import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/features/chat/services/fetchable_url_policy.dart';

void main() {
  const policy = FetchableUrlPolicy();
  bool ok(String url) => policy.allows(Uri.parse(url));

  group('FetchableUrlPolicy.allows', () {
    test('allows an ordinary https site', () {
      expect(ok('https://www.instagram.com/reel/abc/'), isTrue);
    });

    test('allows an ordinary http site', () {
      expect(ok('http://example.com/a'), isTrue);
    });

    test('allows a public IP address', () {
      expect(ok('http://93.184.216.34/'), isTrue);
    });

    test('rejects a scheme other than http/https', () {
      expect(ok('ftp://example.com/'), isFalse);
    });

    test('rejects localhost', () {
      expect(ok('http://localhost:8080/'), isFalse);
    });

    test('rejects a loopback address', () {
      expect(ok('http://127.0.0.1/'), isFalse);
    });

    test('rejects a 10.x private address', () {
      expect(ok('http://10.0.0.5/'), isFalse);
    });

    test('rejects a 192.168.x private address', () {
      expect(ok('http://192.168.1.1/'), isFalse);
    });

    test('rejects a 172.16-31 private address', () {
      expect(ok('http://172.20.0.1/'), isFalse);
    });

    test('allows 172.32.x, which is not private', () {
      expect(ok('http://172.32.0.1/'), isTrue);
    });

    test('rejects a link-local address', () {
      expect(ok('http://169.254.169.254/latest/meta-data'), isFalse);
    });

    test('rejects the IPv6 loopback', () {
      expect(ok('http://[::1]/'), isFalse);
    });

    test('rejects an IPv6 unique-local address', () {
      expect(ok('http://[fd00::1]/'), isFalse);
    });

    test('rejects a .local name', () {
      expect(ok('http://printer.local/'), isFalse);
    });

    test('rejects a single-label intranet name', () {
      expect(ok('http://intranet/'), isFalse);
    });

    test('rejects an address with embedded credentials', () {
      expect(ok('https://user:pass@example.com/'), isFalse);
    });
  });
}
