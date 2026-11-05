import 'package:flutter/foundation.dart';

/// Lightweight projection of a peer's identity + transport keys, used
/// when bootstrapping a new group conversation. Construct from an
/// existing 1:1 `Conversation` by reading its peer fields (Plan C §10.2).
@immutable
class MemberSeed {
  const MemberSeed({
    required this.accountId,
    required this.username,
    required this.deviceId,
    required this.identityPubKey,
    required this.x25519PubKey,
  });
  final String accountId;
  final String username;
  final String deviceId;
  final List<int> identityPubKey;
  final List<int> x25519PubKey;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MemberSeed &&
          accountId == other.accountId &&
          username == other.username &&
          deviceId == other.deviceId &&
          listEquals(identityPubKey, other.identityPubKey) &&
          listEquals(x25519PubKey, other.x25519PubKey);

  @override
  int get hashCode => Object.hash(
        accountId,
        username,
        deviceId,
        Object.hashAll(identityPubKey),
        Object.hashAll(x25519PubKey),
      );
}
