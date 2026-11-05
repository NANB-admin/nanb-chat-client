import 'package:flutter/foundation.dart';

@immutable
class JwtSession {
  const JwtSession({
    required this.accountId,
    required this.deviceId,
    required this.jwt,
    required this.username,
  });

  final String accountId;
  final String deviceId;
  final String jwt;
  final String username;

  factory JwtSession.fromJson(Map<String, dynamic> json) => JwtSession(
        accountId: json['account_id'] as String,
        deviceId: json['device_id'] as String,
        jwt: json['jwt'] as String,
        username: json['username'] as String,
      );

  Map<String, dynamic> toJson() => {
        'account_id': accountId,
        'device_id': deviceId,
        'jwt': jwt,
        'username': username,
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is JwtSession &&
          accountId == other.accountId &&
          deviceId == other.deviceId &&
          jwt == other.jwt &&
          username == other.username;

  @override
  int get hashCode => Object.hash(accountId, deviceId, jwt, username);
}
