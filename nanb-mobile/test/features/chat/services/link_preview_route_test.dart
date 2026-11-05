import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/core/network/socks_proxy.dart';
import 'package:nanb_chat/features/chat/services/link_preview_route.dart';
import 'package:nanb_chat/features/settings/models/link_preview_mode.dart';

const _tor = SocksProxyConfig(host: '127.0.0.1', port: 9050);

LinkPreviewRoute _resolve(
  LinkPreviewMode mode, {
  SocksProxyConfig? socks,
  bool ready = true,
}) =>
    LinkPreviewRoute.resolve(mode: mode, socks: socks, socksReady: ready);

void main() {
  group('LinkPreviewRoute.resolve', () {
    test('off never fetches, even with Tor up', () {
      expect(_resolve(LinkPreviewMode.off, socks: _tor).allowed, isFalse);
    });

    test('Tor-only fetches through the proxy when it is ready', () {
      final r = _resolve(LinkPreviewMode.viaTor, socks: _tor);

      expect(r.allowed, isTrue);
      expect(r.proxy, _tor);
    });

    test('Tor-only does not fetch while the proxy is still connecting', () {
      expect(
          _resolve(LinkPreviewMode.viaTor, socks: _tor, ready: false).allowed,
          isFalse);
    });

    test('Tor-only does not fetch with no proxy at all', () {
      expect(_resolve(LinkPreviewMode.viaTor).allowed, isFalse);
    });

    test('always fetches directly when there is no proxy', () {
      final r = _resolve(LinkPreviewMode.always);

      expect(r.allowed, isTrue);
      expect(r.proxy, isNull);
    });

    test('always still goes through the proxy when one is ready', () {
      expect(_resolve(LinkPreviewMode.always, socks: _tor).proxy, _tor);
    });

    test('always never bypasses a proxy that is still connecting', () {
      expect(
          _resolve(LinkPreviewMode.always, socks: _tor, ready: false).allowed,
          isFalse);
    });
  });
}
