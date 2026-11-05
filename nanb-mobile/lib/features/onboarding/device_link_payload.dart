import '../../core/models/device_kind.dart';

/// Wire format for the
/// `nanb-link://device?id=<handleId>&pk=<hexEdPubKey>&xk=<hexX25519PubKey>` URI
/// that the new device shows as a QR code on `LinkNewDeviceScreen` and the
/// already-signed-in primary device scans on `LinkPrimaryDeviceScreen`.
///
/// `pk` is the new device's own Ed25519 key (used for session auth + as the
/// link-authorization subject). `xk` is its own X25519 key — peers run a
/// per-device ratchet against it. Both are generated on the new device and are
/// NOT derived from the recovery phrase.
class DeviceLinkPayload {
  const DeviceLinkPayload({
    required this.handleId,
    required this.publicKey,
    this.x25519PublicKey = const [],
    this.kind = DeviceKind.phone,
  });

  /// Opaque identifier from the new device's `IdentityHandle.id`.
  final String handleId;

  /// Raw 32-byte Ed25519 public key (decoded from the hex `pk` query param).
  final List<int> publicKey;

  /// Raw 32-byte X25519 public key (decoded from the hex `xk` query param).
  /// Empty when scanned from an older new-device build that omitted it.
  final List<int> x25519PublicKey;

  /// What the new device says it is (`kind` query param). Missing or unknown
  /// => phone. Web QRs carry kind=web so the scanning phone can warn first.
  final DeviceKind kind;

  /// Hex of [publicKey] — the form the unauthenticated pending-device poll is
  /// keyed by on the server.
  String get publicKeyHex => _bytesToHex(publicKey);

  /// Builds the QR string the new device displays.
  static String buildUri({
    required String handleId,
    required List<int> publicKey,
    required List<int> x25519PublicKey,
    DeviceKind kind = DeviceKind.phone,
  }) {
    final pk = _bytesToHex(publicKey);
    final xk = _bytesToHex(x25519PublicKey);
    final base = 'nanb-link://device?id=$handleId&pk=$pk&xk=$xk';
    // Phone QRs stay byte-identical to older builds.
    return kind == DeviceKind.web ? '$base&kind=${kind.wire}' : base;
  }

  static String _bytesToHex(List<int> bytes) => bytes
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();

  /// First 12 hex chars in 4-char groups, e.g. "A1B2 C3D4 E5F6". Matches the
  /// fingerprint format shown on `LinkNewDeviceScreen`.
  String get fingerprint {
    final hex = publicKey
        .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
        .join();
    final pairs = <String>[];
    for (var i = 0; i < hex.length && i < 12; i += 4) {
      pairs.add(hex.substring(i, i + 4));
    }
    return pairs.join(' ');
  }

  /// Parses a scanned QR string. Throws [FormatException] for any mismatch
  /// (wrong scheme/host, missing params, malformed hex, wrong key length).
  static DeviceLinkPayload parse(String raw) {
    final Uri uri;
    try {
      uri = Uri.parse(raw);
    } catch (_) {
      throw const FormatException('not a URI');
    }
    if (uri.scheme != 'nanb-link') {
      throw FormatException('expected scheme nanb-link, got ${uri.scheme}');
    }
    if (uri.host != 'device') {
      throw FormatException('expected host "device", got ${uri.host}');
    }
    final id = uri.queryParameters['id'];
    final pkHex = uri.queryParameters['pk'];
    final xkHex = uri.queryParameters['xk'];
    if (id == null || id.isEmpty) {
      throw const FormatException('missing id');
    }
    if (pkHex == null || pkHex.isEmpty) {
      throw const FormatException('missing pk');
    }
    final pubKey = _hexToBytes(pkHex);
    if (pubKey.length != 32) {
      throw FormatException('pk must be 32 bytes, got ${pubKey.length}');
    }
    // xk (X25519) is optional for forward-compat with older QR producers, but
    // when present must be a valid 32-byte key.
    var x25519 = const <int>[];
    if (xkHex != null && xkHex.isNotEmpty) {
      x25519 = _hexToBytes(xkHex);
      if (x25519.length != 32) {
        throw FormatException('xk must be 32 bytes, got ${x25519.length}');
      }
    }
    return DeviceLinkPayload(
      handleId: id,
      publicKey: pubKey,
      x25519PublicKey: x25519,
      kind: DeviceKind.fromWire(uri.queryParameters['kind']),
    );
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
