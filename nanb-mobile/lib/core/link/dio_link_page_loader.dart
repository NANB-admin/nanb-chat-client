import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

import '../../features/chat/services/fetchable_url_policy.dart';
import '../../features/chat/services/link_page_loader.dart';
import '../network/socks_proxy.dart';

/// Fetches link-preview pages and images over HTTP, tunnelled through the
/// [socksProxy] (Tor) exactly like the rest of the app's traffic.
///
/// Hardened for hostile input: tiny size caps, short timeouts, no cookies or
/// credentials, only HTML / raster-image content types, and redirects followed by
/// hand (at most [maxRedirects]) so every hop is re-checked against
/// [FetchableUrlPolicy] — a public link can't bounce the fetch onto a private
/// address.
class DioLinkPageLoader implements LinkPageLoader {
  DioLinkPageLoader({
    SocksProxyConfig? socksProxy,
    Dio? dio,
    FetchableUrlPolicy policy = const FetchableUrlPolicy(),
  })  : _dio = dio ?? _build(socksProxy),
        _policy = policy;

  static const maxHtmlBytes = 512 * 1024;
  static const maxImageBytes = 1536 * 1024;
  static const maxRedirects = 3;

  /// An honest, generic client name: sites hand Open Graph tags to any bot that
  /// identifies itself, and we don't pretend to be someone else's crawler.
  static const _userAgent = 'Mozilla/5.0 (compatible; NANbLinkPreview/1.0)';

  final Dio _dio;
  final FetchableUrlPolicy _policy;

  static Dio _build(SocksProxyConfig? socksProxy) {
    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 12),
      receiveTimeout: const Duration(seconds: 12),
    ));
    if (socksProxy != null) {
      dio.httpClientAdapter = IOHttpClientAdapter(
        createHttpClient: () => buildHttpClient(socksProxy),
      );
    }
    return dio;
  }

  @override
  Future<String?> loadHtml(Uri url) async {
    // The head is at the front, so an oversized page is truncated, not rejected.
    final bytes = await _get(
      url,
      accept: 'text/html,application/xhtml+xml',
      maxBytes: maxHtmlBytes,
      allowTruncation: true,
      acceptsType: (t) => t.contains('html'),
    );
    return bytes == null ? null : utf8.decode(bytes, allowMalformed: true);
  }

  @override
  Future<List<int>?> loadImage(Uri url) {
    return _get(
      url,
      accept: 'image/*',
      maxBytes: maxImageBytes,
      allowTruncation: false,
      // SVG can carry script and external references; never decode it.
      acceptsType: (t) => t.startsWith('image/') && !t.contains('svg'),
    );
  }

  Future<List<int>?> _get(
    Uri url, {
    required String accept,
    required int maxBytes,
    required bool allowTruncation,
    required bool Function(String contentType) acceptsType,
  }) async {
    try {
      var current = url;
      for (var hop = 0; hop <= maxRedirects; hop++) {
        if (!_policy.allows(current)) return null;
        final res = await _dio.getUri<ResponseBody>(
          current,
          options: Options(
            responseType: ResponseType.stream,
            followRedirects: false,
            validateStatus: (_) => true,
            headers: {'User-Agent': _userAgent, 'Accept': accept},
          ),
        );
        final status = res.statusCode ?? 0;
        if (status >= 300 && status < 400) {
          final location = res.headers.value('location');
          if (location == null) return null;
          current = current.resolve(location);
          continue;
        }
        if (status < 200 || status >= 300) return null;
        final type = (res.headers.value('content-type') ?? '').toLowerCase();
        if (!acceptsType(type)) return null;
        return _readCapped(res.data!, maxBytes, allowTruncation);
      }
      return null; // too many redirects
    } catch (_) {
      return null;
    }
  }

  Future<List<int>?> _readCapped(
    ResponseBody body,
    int maxBytes,
    bool allowTruncation,
  ) async {
    final out = BytesBuilder(copy: false);
    await for (final chunk in body.stream) {
      if (out.length + chunk.length > maxBytes) {
        if (!allowTruncation) return null;
        out.add(chunk.sublist(0, maxBytes - out.length));
        break;
      }
      out.add(chunk);
    }
    return out.takeBytes();
  }

  void close() => _dio.close(force: true);
}
