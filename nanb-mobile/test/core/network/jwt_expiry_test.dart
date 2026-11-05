import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/core/network/jwt_expiry.dart';

/// Builds a minimal JWT string with the provided claim payload. The
/// header and signature segments are fixed placeholders — the parser
/// under test only cares about the middle (payload) segment.
String _makeJwt(Map<String, dynamic> claims) {
  String b64url(String s) => base64Url.encode(utf8.encode(s)).replaceAll('=', '');
  final header = b64url('{"alg":"EdDSA","typ":"JWT"}');
  final payload = b64url(jsonEncode(claims));
  const signature = 'placeholder-signature';
  return '$header.$payload.$signature';
}

void main() {
  group('jwtExpiry', () {
    test('parses a valid exp claim into a UTC DateTime', () {
      final exp = 1750000000;
      final jwt = _makeJwt({'sub': 'acc', 'exp': exp});
      expect(
        jwtExpiry(jwt),
        DateTime.fromMillisecondsSinceEpoch(exp * 1000, isUtc: true),
      );
    });

    test('returns null when exp claim is missing', () {
      final jwt = _makeJwt({'sub': 'acc'});
      expect(jwtExpiry(jwt), isNull);
    });

    test('returns null when the JWT does not have three dot-separated segments', () {
      expect(jwtExpiry('only.two'), isNull);
      expect(jwtExpiry('a.b.c.d'), isNull);
    });

    test('returns null when the middle segment is not base64url', () {
      expect(jwtExpiry('header.@@not-base64@@.sig'), isNull);
    });

    test('returns null when exp claim is not a number', () {
      final jwt = _makeJwt({'exp': 'not-a-number'});
      expect(jwtExpiry(jwt), isNull);
    });
  });
}
