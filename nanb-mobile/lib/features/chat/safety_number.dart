import 'package:cryptography/cryptography.dart';

/// Signal-style 60-digit safety number derived from the two participants'
/// identity public keys. Both peers compute the same number because we sort
/// the two keys lexically before hashing.
///
/// This is a UX helper, not a cryptographic primitive. The protocol-level
/// authenticity check is the Ed25519 signature on the server's username
/// claim and the per-message MLS commits — the safety number gives the user
/// a way to confirm out-of-band that they're talking to who they think.
class SafetyNumber {
  SafetyNumber._();

  static Future<String> compute({
    required List<int> mineKey,
    required List<int> peerKey,
  }) async {
    // Empty == "can't compute" (one side's identity key isn't known yet). The
    // caller distinguishes this from null (still loading) to show a clear
    // "not available" state instead of a dead Copy button on placeholder dots.
    if (mineKey.isEmpty || peerKey.isEmpty) {
      return '';
    }
    final ordered = [mineKey, peerKey];
    ordered.sort(_compareBytes);
    final combined = <int>[...ordered[0], ...ordered[1]];
    // SHA-512 (64 bytes) carries enough material for 60 decimal digits — 12
    // five-byte chunks → 12 groups of 5. SHA-256 (32 bytes) only makes 30, so
    // the old code over-requested 60 and the final substring threw a RangeError,
    // meaning the number NEVER rendered (the screen sat on placeholder dots).
    final hash = await Sha512().hash(combined);
    return _digitsFromBytes(hash.bytes, 60);
  }

  /// Splits a 60-digit number into 12 groups of 5 characters for display.
  static List<String> split(String number) {
    final cleaned = number.replaceAll(RegExp(r'[^0-9]'), '');
    final groups = <String>[];
    for (var i = 0; i < cleaned.length; i += 5) {
      groups.add(cleaned.substring(i, (i + 5).clamp(0, cleaned.length)));
    }
    return groups;
  }

  static int _compareBytes(List<int> a, List<int> b) {
    final n = a.length < b.length ? a.length : b.length;
    for (var i = 0; i < n; i++) {
      if (a[i] != b[i]) return a[i] - b[i];
    }
    return a.length - b.length;
  }

  /// Converts hash bytes into up to `digitCount` decimal digits by reducing
  /// each 5-byte chunk mod 100000 and zero-padding to 5 digits. Needs
  /// `digitCount / 5 * 5` bytes of input (60 digits → 60 bytes); SHA-512's 64
  /// bytes cover it. Clamps to what's available so it never over-runs the
  /// buffer (the old `substring(0, 60)` on 30 digits threw a RangeError).
  static String _digitsFromBytes(List<int> bytes, int digitCount) {
    final out = StringBuffer();
    var i = 0;
    while (out.length < digitCount && i + 5 <= bytes.length) {
      var v = 0;
      for (var k = 0; k < 5; k++) {
        v = (v << 8) | (bytes[i + k] & 0xff);
      }
      v %= 100000;
      out.write(v.toString().padLeft(5, '0'));
      i += 5;
    }
    final s = out.toString();
    return s.substring(0, digitCount < s.length ? digitCount : s.length);
  }
}
