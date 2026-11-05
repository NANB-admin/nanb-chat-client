import '../../../core/network/socks_proxy.dart';
import '../../settings/models/link_preview_mode.dart';

/// How (and whether) a link preview may reach the network right now.
///
/// The one rule that matters: with a proxy configured, a fetch goes THROUGH it or
/// not at all — it never falls back to a direct connection, not even while the
/// proxy is still bootstrapping.
class LinkPreviewRoute {
  const LinkPreviewRoute._({required this.allowed}) : proxy = null;

  /// No fetch.
  static const none = LinkPreviewRoute._(allowed: false);

  /// Fetch directly (the site sees this device's IP).
  static const direct = LinkPreviewRoute._(allowed: true);

  /// Fetch through [proxy].
  const LinkPreviewRoute.viaProxy(SocksProxyConfig this.proxy) : allowed = true;

  final bool allowed;

  /// The SOCKS proxy to tunnel through; null means a direct connection.
  final SocksProxyConfig? proxy;

  /// [socks] is the app's current SOCKS config (null = no proxy in use) and
  /// [socksReady] is whether that proxy is actually carrying traffic (false while
  /// the in-app Tor is still connecting).
  static LinkPreviewRoute resolve({
    required LinkPreviewMode mode,
    required SocksProxyConfig? socks,
    required bool socksReady,
  }) {
    if (mode == LinkPreviewMode.off) return none;
    if (socks != null) {
      return socksReady ? LinkPreviewRoute.viaProxy(socks) : none;
    }
    return mode == LinkPreviewMode.always ? direct : none;
  }
}
