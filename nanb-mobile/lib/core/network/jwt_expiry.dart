import 'dart:convert';

/// Parses the `exp` claim out of a JWT and returns it as a UTC
/// `DateTime`. Returns null for any malformed input — callers should
/// treat null as "refresh required".
///
/// Does NOT verify the signature — that's the server's job. This
/// function exists so the client can avoid an unnecessary
/// challenge/sign/submit refresh round-trip when the JWT is clearly
/// still valid.
DateTime? jwtExpiry(String jwt) {
  final segments = jwt.split('.');
  if (segments.length != 3) return null;
  try {
    final padded = _padBase64(segments[1]);
    final payloadBytes = base64Url.decode(padded);
    final payloadJson = utf8.decode(payloadBytes);
    final claims = jsonDecode(payloadJson);
    if (claims is! Map<String, dynamic>) return null;
    final exp = claims['exp'];
    if (exp is! int) return null;
    return DateTime.fromMillisecondsSinceEpoch(exp * 1000, isUtc: true);
  } catch (_) {
    return null;
  }
}

/// `base64Url` requires the input length to be a multiple of 4. JWT
/// segments are stripped of trailing `=` — re-pad before decoding.
String _padBase64(String s) {
  final mod = s.length % 4;
  if (mod == 0) return s;
  return s + ('=' * (4 - mod));
}
