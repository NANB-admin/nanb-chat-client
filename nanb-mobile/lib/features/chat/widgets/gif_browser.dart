import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/design_tokens.dart';
import '../../../app/providers.dart';
import '../../../core/gif/gif_client.dart';
import '../../../core/gif/gif_result.dart';

/// GIF search + grid, designed to embed inside another surface (the emoji
/// panel's "GIF" tab). Shows trending GIFs on open, debounces typing, and calls
/// [onSelected] with the tapped GIF — it does NOT send anything itself; the host
/// downloads the bytes and routes them through the encrypted media pipeline.
///
/// Search/trending go through the nanb-server GIF proxy (so the provider API key
/// stays server-side); the client is built from the app's base URL + session JWT.
class GifBrowser extends ConsumerStatefulWidget {
  const GifBrowser({super.key, required this.onSelected, this.client});

  final ValueChanged<GifResult> onSelected;

  /// Injectable for tests; when null a live proxy-backed client is built from
  /// the app providers.
  final GifClient? client;

  @override
  ConsumerState<GifBrowser> createState() => _GifBrowserState();
}

class _GifBrowserState extends ConsumerState<GifBrowser> {
  GifClient? _client;
  bool _ownsClient = false;
  final _searchController = TextEditingController();
  Timer? _debounce;

  List<GifResult> _gifs = const [];
  bool _loading = true;
  bool _hadError = false;

  /// Monotonic request id so a slow earlier response can't overwrite a newer
  /// query's results (out-of-order race on fast typing).
  int _requestSeq = 0;

  /// Memoised thumbnail byte-fetches, keyed by preview URL. Thumbnails are
  /// pulled through the server's `/gifs/media` proxy (over Tor when enabled),
  /// NOT `Image.network` — `Image.network` uses Flutter's default HttpClient,
  /// which ignores our SOCKS proxy and would fetch the provider CDN directly
  /// from the user's real IP, deanonymising every open of the picker. Memoising
  /// the future means each GIF is fetched once and scroll/rebuilds don't re-hit
  /// the proxy. Cleared on a new query (the visible set changes).
  final Map<String, Future<Uint8List>> _thumbs = {};

  Future<Uint8List> _thumb(String url) {
    return _thumbs.putIfAbsent(url, () async {
      final client = _client;
      if (client == null) throw StateError('gif client not ready');
      return Uint8List.fromList(await client.downloadBytes(url));
    });
  }

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    if (widget.client != null) {
      _client = widget.client;
    } else {
      // Base URL + SOCKS config are synchronous; the JWT comes from the session.
      final baseUrl = ref.read(apiBaseUrlProvider);
      final socks = ref.read(socksProxyProvider);
      final session = await ref.read(sessionRepositoryProvider).current();
      if (!mounted) return;
      _client = GifClient(
        baseUrl: baseUrl,
        bearerToken: session?.jwt,
        socksProxy: socks,
      );
      _ownsClient = true;
    }
    // Honour anything typed during the brief async build; else load trending.
    await _load(_searchController.text);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    if (_ownsClient) _client?.close();
    super.dispose();
  }

  void _onQueryChanged(String q) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () => _load(q));
  }

  Future<void> _load(String query) async {
    final client = _client;
    if (client == null) return; // not built yet; _init() will fire the first load
    final seq = ++_requestSeq;
    setState(() {
      _loading = true;
      _hadError = false;
    });
    try {
      final results = await client.search(query);
      if (!mounted || seq != _requestSeq) return;
      setState(() {
        _thumbs.clear(); // new result set → drop the previous query's thumbnails
        _gifs = results;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || seq != _requestSeq) return;
      setState(() {
        _hadError = true;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = DesignTokens.of(context);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 6),
          child: SizedBox(
            height: 40,
            child: TextField(
              controller: _searchController,
              onChanged: _onQueryChanged,
              textInputAction: TextInputAction.search,
              style: TextStyle(color: t.text, fontSize: 14),
              decoration: InputDecoration(
                hintText: 'Search GIPHY',
                hintStyle: TextStyle(color: t.textFaint),
                prefixIcon: Icon(Icons.search, size: 18, color: t.textMuted),
                filled: true,
                fillColor: t.surfaceAlt,
                isDense: true,
                contentPadding: EdgeInsets.zero,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
        ),
        Expanded(child: _body(t)),
        _attribution(t),
      ],
    );
  }

  Widget _body(DesignTokens t) {
    if (_loading) {
      return const Center(
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (_hadError) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text("Couldn't load GIFs.", style: TextStyle(color: t.textMuted)),
            const SizedBox(height: 4),
            TextButton(
              onPressed: () => _load(_searchController.text),
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }
    if (_gifs.isEmpty) {
      return Center(
        child: Text('No GIFs found', style: TextStyle(color: t.textMuted)),
      );
    }
    // Uniform square grid with cover-fit animated previews — clean and avoids a
    // staggered-grid package. Cell count adapts to width.
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 110,
        mainAxisSpacing: 6,
        crossAxisSpacing: 6,
      ),
      itemCount: _gifs.length,
      itemBuilder: (context, i) {
        final gif = _gifs[i];
        return GestureDetector(
          onTap: () => widget.onSelected(gif),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: ColoredBox(
              color: t.surfaceAlt,
              // Bytes come through the proxy client (see [_thumb]) and render
              // from memory — NOT Image.network, which would bypass Tor.
              child: FutureBuilder<Uint8List>(
                future: _thumb(gif.previewUrl),
                builder: (context, snap) {
                  if (snap.connectionState != ConnectionState.done) {
                    return const Center(
                      child: SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 1.5),
                      ),
                    );
                  }
                  final bytes = snap.data;
                  if (snap.hasError || bytes == null) {
                    return Icon(Icons.broken_image_outlined, color: t.textFaint);
                  }
                  return Image.memory(
                    bytes,
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }

  // GIPHY's terms require visible attribution wherever their content appears.
  Widget _attribution(DesignTokens t) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 4),
      alignment: Alignment.center,
      child: Text(
        'POWERED BY GIPHY',
        style: TextStyle(
          color: t.textFaint,
          fontSize: 9,
          fontWeight: FontWeight.w600,
          letterSpacing: 1.2,
        ),
      ),
    );
  }
}
