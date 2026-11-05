/// Short-lived WebRTC TURN credentials issued by `GET /turn/credentials`
/// (coturn use-auth-secret). Fed straight into the call engine's ICE config.
class TurnCredentials {
  const TurnCredentials({
    required this.urls,
    required this.username,
    required this.credential,
    required this.ttlSeconds,
  });

  final List<String> urls;
  final String username;
  final String credential;
  final int ttlSeconds;

  factory TurnCredentials.fromJson(Map<String, dynamic> json) => TurnCredentials(
        urls: (json['urls'] as List).map((e) => e as String).toList(),
        username: json['username'] as String,
        credential: json['credential'] as String,
        ttlSeconds: json['ttl'] as int,
      );
}
