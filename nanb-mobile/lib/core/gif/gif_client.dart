import 'package:dio/dio.dart';
import 'package:dio/io.dart';

import '../network/socks_proxy.dart';
import 'gif_result.dart';

/// Calls the **nanb-server GIF proxy** (`/gifs/search`, `/gifs/trending`,
/// `/gifs/media`) rather than the GIF provider (Giphy) directly, so the provider
/// API key lives only on the server and never ships inside the app binary, and
/// the provider never sees the user's IP. The proxy returns a normalized shape
/// ([GifResult]), so the client is independent of the provider's schema.
///
/// Requests are authenticated with the session JWT (same auth as the rest of the
/// API) and, when [socksProxy] is set, tunnelled through the local SOCKS5 (Tor)
/// proxy — mirroring `ApiClientDio` so GIF traffic routes identically to every
/// other request.
class GifClient {
  GifClient({
    required String baseUrl,
    String? bearerToken,
    SocksProxyConfig? socksProxy,
    Dio? dio,
  }) : _dio = dio ?? _build(baseUrl, bearerToken, socksProxy);

  static Dio _build(
    String baseUrl,
    String? bearerToken,
    SocksProxyConfig? socksProxy,
  ) {
    final dio = Dio(BaseOptions(
      baseUrl: baseUrl,
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 15),
      headers: {
        if (bearerToken != null) 'Authorization': 'Bearer $bearerToken',
      },
    ));
    if (socksProxy != null) {
      // Route through the SOCKS5 proxy (Tor) exactly like ApiClientDio, so the
      // proxy can do remote DNS for .onion targets and onion-route the request.
      dio.httpClientAdapter = IOHttpClientAdapter(
        createHttpClient: () => buildHttpClient(socksProxy),
      );
    }
    return dio;
  }

  final Dio _dio;

  Future<List<GifResult>> trending({int limit = 30}) =>
      _fetch('/gifs/trending', {'limit': '$limit'});

  /// Searches via the proxy; an empty query falls back to trending so the picker
  /// always shows something on open.
  Future<List<GifResult>> search(String query, {int limit = 30}) {
    final q = query.trim();
    if (q.isEmpty) return trending(limit: limit);
    return _fetch('/gifs/search', {'q': q, 'limit': '$limit'});
  }

  /// Downloads a chosen GIF's bytes through the server's media proxy
  /// (`/gifs/media`), so the download leaves the server's IP rather than the
  /// user's. [mediaUrl] is the provider CDN URL from a [GifResult]; the server
  /// validates it's an allowed (Giphy) host before fetching.
  Future<List<int>> downloadBytes(String mediaUrl) async {
    final res = await _dio.get<List<int>>(
      '/gifs/media',
      queryParameters: {'url': mediaUrl},
      options: Options(
        responseType: ResponseType.bytes,
        receiveTimeout: const Duration(minutes: 1),
      ),
    );
    return List<int>.from(res.data ?? const <int>[]);
  }

  Future<List<GifResult>> _fetch(
    String path,
    Map<String, String> params,
  ) async {
    final res = await _dio.get<Map<String, dynamic>>(
      path,
      queryParameters: params,
    );
    final data = res.data?['data'];
    if (data is! List) return const [];
    return data
        .whereType<Map<String, dynamic>>()
        .map(GifResult.fromJson)
        .whereType<GifResult>()
        .toList(growable: false);
  }

  void close() => _dio.close(force: true);
}
