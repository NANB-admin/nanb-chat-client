/// Wire format for the `nanb-link://contact?u=<username>&pk=<hexPubKey>` URI
/// rendered as the identity QR on the settings hub. The follow-up
/// scan-to-add flow (new-chat screen "Other ways to add") parses this to
/// start a chat with the key pre-verified out-of-band.
///
/// Mirrors [DeviceLinkPayload] (`nanb-link://device?...`) so a future
/// scanner can dispatch on the URI host.
class ContactLinkPayload {
  const ContactLinkPayload({required this.username, required this.publicKey});

  /// Bare username (no leading `@`).
  final String username;

  /// Raw 32-byte Ed25519 identity public key.
  final List<int> publicKey;

  /// Encodes to the QR string.
  String encode() {
    final hex = publicKey
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    return 'nanb-link://contact?u=${Uri.encodeQueryComponent(username)}&pk=$hex';
  }

  /// First 12 hex chars in 4-char groups, e.g. "A1B2 C3D4 E5F6" — same
  /// format as [DeviceLinkPayload.fingerprint] and the settings card.
  String get fingerprint {
    final hex = publicKey
        .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
        .join();
    final pairs = <String>[];
    for (var i = 0; i + 4 <= hex.length && pairs.length < 3; i += 4) {
      pairs.add(hex.substring(i, i + 4));
    }
    return pairs.join(' ');
  }

  /// Parses a scanned QR string. Throws [FormatException] for any mismatch
  /// (wrong scheme/host, missing params, malformed hex, wrong key length).
  static ContactLinkPayload parse(String raw) {
    final Uri uri;
    try {
      uri = Uri.parse(raw);
    } catch (_) {
      throw const FormatException('not a URI');
    }
    if (uri.scheme != 'nanb-link') {
      throw FormatException('expected scheme nanb-link, got ${uri.scheme}');
    }
    if (uri.host != 'contact') {
      throw FormatException('expected host "contact", got ${uri.host}');
    }
    final username = uri.queryParameters['u'];
    final pkHex = uri.queryParameters['pk'];
    if (username == null || username.isEmpty) {
      throw const FormatException('missing u');
    }
    if (pkHex == null || pkHex.isEmpty) {
      throw const FormatException('missing pk');
    }
    final pubKey = _hexToBytes(pkHex);
    if (pubKey.length != 32) {
      throw FormatException('pk must be 32 bytes, got ${pubKey.length}');
    }
    return ContactLinkPayload(username: username, publicKey: pubKey);
  }

  static List<int> _hexToBytes(String hex) {
    if (hex.length % 2 != 0) {
      throw FormatException('odd-length hex: ${hex.length}');
    }
    final out = <int>[];
    for (var i = 0; i < hex.length; i += 2) {
      final byte = int.tryParse(hex.substring(i, i + 2), radix: 16);
      if (byte == null) {
        throw FormatException('non-hex character at offset $i');
      }
      out.add(byte);
    }
    return out;
  }
}
