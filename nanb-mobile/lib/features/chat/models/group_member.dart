import 'package:flutter/foundation.dart';

/// A single member of an MLS group (spec §10.1). Mirrored to the SQLCipher
/// `group_members` table; reconstructed in memory when a conversation is
/// loaded. The crypto truth lives in CoreCrypto's store — this is a
/// diagnostic + UI projection.
@immutable
class GroupMember {
  const GroupMember({
    required this.accountId,
    required this.username,
    required this.deviceId,
    required this.identityPubKey,
    required this.x25519PubKey,
    required this.isAdmin,
    required this.isSelf,
  });

  final String accountId;
  final String username;
  final String deviceId;
  final List<int> identityPubKey;
  final List<int> x25519PubKey;

  /// Advisory only — MLS itself has no role system in v1 (spec §10.7).
  /// `true` for the group creator; unchangeable in v1.
  final bool isAdmin;

  /// `true` when this member entry represents the current device's user.
  /// UI uses it to hide the "Remove" action on yourself and to label "You".
  final bool isSelf;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GroupMember &&
          accountId == other.accountId &&
          username == other.username &&
          deviceId == other.deviceId &&
          listEquals(identityPubKey, other.identityPubKey) &&
          listEquals(x25519PubKey, other.x25519PubKey) &&
          isAdmin == other.isAdmin &&
          isSelf == other.isSelf;

  @override
  int get hashCode => Object.hash(
        accountId,
        username,
        deviceId,
        Object.hashAll(identityPubKey),
        Object.hashAll(x25519PubKey),
        isAdmin,
        isSelf,
      );
}
