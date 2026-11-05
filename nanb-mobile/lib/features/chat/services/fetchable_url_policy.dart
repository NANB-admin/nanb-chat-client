import 'dart:io';

/// Which addresses a link preview may fetch. A link in a message is attacker
/// controlled, so the fetch must never be steerable at the sender's own network
/// (a router page, a cloud metadata endpoint, an intranet host) or carry
/// credentials. Only plain http(s) to a public-looking host passes.
class FetchableUrlPolicy {
  const FetchableUrlPolicy();

  bool allows(Uri url) {
    if (url.scheme != 'http' && url.scheme != 'https') return false;
    if (url.userInfo.isNotEmpty) return false;
    final host = url.host.toLowerCase();
    if (host.isEmpty) return false;

    final ip = InternetAddress.tryParse(host);
    if (ip != null) return !_isPrivate(ip);

    if (host == 'localhost' || host.endsWith('.localhost')) return false;
    if (host.endsWith('.local') || host.endsWith('.internal')) return false;
    // A single-label name ("intranet") only resolves on a private network.
    if (!host.contains('.')) return false;
    return true;
  }

  bool _isPrivate(InternetAddress ip) {
    if (ip.isLoopback || ip.isLinkLocal || ip.isMulticast) return true;
    final b = ip.rawAddress;
    if (ip.type == InternetAddressType.IPv4) {
      if (b[0] == 0) return true; // "this network"
      if (b[0] == 10) return true;
      if (b[0] == 172 && b[1] >= 16 && b[1] <= 31) return true;
      if (b[0] == 192 && b[1] == 168) return true;
      if (b[0] == 100 && b[1] >= 64 && b[1] <= 127) return true; // CGNAT
      return false;
    }
    // IPv6: unique-local fc00::/7, and the unspecified address.
    if ((b[0] & 0xFE) == 0xFC) return true;
    return b.every((x) => x == 0);
  }
}
