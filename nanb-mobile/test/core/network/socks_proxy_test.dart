import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/core/network/socks_proxy.dart';

void main() {
  group('SocksProxyConfig', () {
    test('value equality + hashCode', () {
      const a = SocksProxyConfig(host: '127.0.0.1', port: 9050);
      const b = SocksProxyConfig(host: '127.0.0.1', port: 9050);
      const c = SocksProxyConfig(host: '127.0.0.1', port: 9150);
      const d = SocksProxyConfig(host: '10.0.0.1', port: 9050);

      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a, isNot(equals(c)));
      expect(a, isNot(equals(d)));
    });
  });

  group('buildHttpClient', () {
    test('returns a direct client when proxy is null', () {
      final client = buildHttpClient(null);
      expect(client, isA<HttpClient>());
      client.close(force: true);
    });

    test('returns a client when proxy host is a literal IP', () {
      const proxy = SocksProxyConfig(host: '127.0.0.1', port: 9050);
      final client = buildHttpClient(proxy);
      expect(client, isA<HttpClient>());
      client.close(force: true);
    });

    test('throws ArgumentError when proxy host is not a literal IP', () {
      const proxy = SocksProxyConfig(host: 'localhost', port: 9050);
      expect(() => buildHttpClient(proxy), throwsArgumentError);
    });
  });
}
