import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Architecture guard (privacy): every outbound network connection in `lib/`
/// MUST go through the single SOCKS chokepoint — `buildHttpClient` in
/// `core/network/socks_proxy.dart` — so that when Tor is enabled NOTHING
/// silently leaks to clearnet. This test scans the source for raw client
/// constructions that would bypass that chokepoint and fails with the offending
/// `file:line`.
///
/// Why a source scan (and not a runtime check): the GIF picker once rendered
/// thumbnails with `Image.network`, which uses Flutter's default HttpClient and
/// ignores our SOCKS proxy — so it fetched GIPHY's CDN directly from the user's
/// real IP whenever the picker was open, deanonymising them even with Tor on
/// (fixed in the giphy thumbnail commit). A unit test can't observe that; a
/// source guard makes the whole *class* of regression fail here instead of in
/// the field.
///
/// If a new file legitimately wires `buildHttpClient` into a client (the way
/// `ApiClientDio`/`GifClient` do), add it to the allow-list below with a note.
void main() {
  // Forbidden construction  ->  the ONLY files allowed to contain it.
  // Empty set = allowed nowhere. Keep this list tight; an addition is a
  // deliberate decision that the new site routes through the SOCKS proxy.
  const allowed = <String, Set<String>>{
    // Raw dart:io HttpClient. The ONE permitted instance is the chokepoint
    // itself; everyone else gets a SOCKS-patched client from buildHttpClient.
    'HttpClient(': {'socks_proxy.dart'},
    // Dio is fine ONLY when its httpClientAdapter is built from buildHttpClient,
    // which these do. A bare `Dio(...)` elsewhere bypasses the proxy.
    // dio_link_page_loader.dart wires the proxy it is given (LinkPreviewRoute
    // decides it) and goes direct ONLY when the user explicitly opted into
    // "previews also when Tor is off"; it never falls back on its own.
    'Dio(': {
      'api_client_dio.dart',
      'gif_client.dart',
      'dio_link_page_loader.dart',
      // Web-only (conditional export): a browser cannot use SOCKS/Tor, so its WS
      // ticket request is necessarily direct. Never compiled into the mobile app.
      'ws_transport_web.dart',
    },
    // The WS upgrade must be handed a SOCKS-patched customClient; only the
    // native WS transport (used by the production WS client) does that.
    'IOWebSocketChannel.connect(': {'ws_transport_io.dart'},
    'WebSocket.connect(': <String>{},
    // Both fetch via Flutter's default HttpClient — they ignore the SOCKS proxy
    // entirely. Render bytes pulled through a proxied client with Image.memory.
    'Image.network(': <String>{},
    'NetworkImage(': <String>{},
  };

  test('no outbound client in lib/ bypasses the SOCKS chokepoint', () {
    final libDir = Directory('lib');
    expect(
      libDir.existsSync(),
      isTrue,
      reason: 'expected to run from the nanb-mobile package root (cwd=${Directory.current.path})',
    );

    final violations = <String>[];
    for (final entity in libDir.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final fileName = entity.uri.pathSegments.last;
      final lines = entity.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        // Strip line comments so doc/inline comments that merely *mention* a
        // forbidden pattern (e.g. "NOT Image.network") don't trip the guard.
        final code = _stripLineComment(lines[i]);
        allowed.forEach((pattern, allowedFiles) {
          if (_containsToken(code, pattern) && !allowedFiles.contains(fileName)) {
            violations.add('${entity.path}:${i + 1}  ->  $pattern');
          }
        });
      }
    }

    expect(
      violations,
      isEmpty,
      reason: 'These call sites build a network client that bypasses '
          'core/network/socks_proxy.dart::buildHttpClient — the SOCKS/Tor '
          'chokepoint — so they would leak to clearnet when Tor is on. Route '
          'them through the proxied ApiClient/GifClient/WsClient (fetch bytes '
          'and render with Image.memory), or, if the file legitimately wires '
          'buildHttpClient, add it to the allow-list in this test:\n'
          '${violations.join('\n')}',
    );
  });
}

/// Returns [line] with any `//` line-comment removed. Good enough for a guard:
/// it can only *remove* text, so it never produces a false positive, and the
/// patterns we look for don't appear inside the URL string literals where a
/// stray `//` could otherwise truncate a line early.
String _stripLineComment(String line) {
  final idx = line.indexOf('//');
  return idx == -1 ? line : line.substring(0, idx);
}

/// True if [pattern] occurs in [code] as its own token — i.e. NOT immediately
/// preceded by an identifier char. Without this, `_closeHttpClient(` would match
/// `HttpClient(`, and `CachedNetworkImage(` would match `NetworkImage(`. All our
/// patterns begin with an uppercase class name, so a preceding identifier char
/// means it's part of a longer name (a method/other class), not the construction
/// we're guarding against.
bool _containsToken(String code, String pattern) {
  var from = 0;
  while (true) {
    final idx = code.indexOf(pattern, from);
    if (idx == -1) return false;
    if (idx == 0 || !_isWordChar(code[idx - 1])) return true;
    from = idx + 1;
  }
}

bool _isWordChar(String c) =>
    RegExp(r'[A-Za-z0-9_]').hasMatch(c);
