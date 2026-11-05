import 'package:flutter/foundation.dart';

import 'json_bytes.dart';

/// One of an account's active devices, as surfaced by `GET /accounts`. Carries
/// the per-device X25519 key a multi-device sender needs to seed a ratchet to
/// each of the peer's devices.
@immutable
class AccountDevice {
  const AccountDevice({
    required this.deviceId,
    this.x25519PubKey = const [],
    this.supportsSealed = false,
  });

  final String deviceId;
  final List<int> x25519PubKey;

  /// Whether this device advertised it can OPEN sealed-sender envelopes
  /// (sealed-sender capability negotiation). A sender only seals to a device
  /// with this true; otherwise it sends unsealed so an old-build device isn't
  /// stranded. Defaults false (conservative) for older servers that omit it.
  final bool supportsSealed;

  factory AccountDevice.fromJson(Map<String, dynamic> json) => AccountDevice(
        deviceId: json['device_id'] as String,
        x25519PubKey: bytesFromJson(json['x25519_pub_key']),
        supportsSealed: json['supports_sealed'] as bool? ?? false,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AccountDevice &&
          deviceId == other.deviceId &&
          listEquals(x25519PubKey, other.x25519PubKey) &&
          supportsSealed == other.supportsSealed;

  @override
  int get hashCode =>
      Object.hash(deviceId, Object.hashAll(x25519PubKey), supportsSealed);
}

/// Server-side account record returned by the identity service.
@immutable
class Account {
  const Account({
    required this.accountId,
    required this.username,
    required this.identityPubKey,
    this.x25519PubKey = const [],
    this.deviceId,
    this.devices = const [],
    this.displayName,
    this.avatarUrl,
  });

  final String accountId;
  final String username;
  final List<int> identityPubKey;

  /// X25519 pub key for ECDH-derived shared secrets (v1 baseline E2EE).
  /// Empty for legacy accounts created before the column existed.
  final List<int> x25519PubKey;

  /// The peer's primary (first active) device id, surfaced by the account
  /// lookup so callers can address messages to a real device. The server
  /// routes/catches-up envelopes by `recipient_device_id`, so this must be a
  /// real device id — not the account id. Null when the server didn't include
  /// it (older server, or no active device).
  final String? deviceId;

  /// Every active device for this account (id + per-device X25519). Empty on
  /// older servers. Multi-device senders fan a 1:1 out to each device here.
  final List<AccountDevice> devices;

  final String? displayName;
  final String? avatarUrl;

  factory Account.fromJson(Map<String, dynamic> json) => Account(
        accountId: json['account_id'] as String,
        username: json['username'] as String,
        identityPubKey: bytesFromJson(json['identity_pub_key']),
        x25519PubKey: bytesFromJson(json['x25519_pub_key']),
        deviceId: json['device_id'] as String?,
        devices: (json['devices'] as List?)
                ?.cast<Map<String, dynamic>>()
                .map(AccountDevice.fromJson)
                .toList(growable: false) ??
            const [],
        displayName: json['display_name'] as String?,
        avatarUrl: json['avatar_url'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'account_id': accountId,
        'username': username,
        'identity_pub_key': identityPubKey,
        if (x25519PubKey.isNotEmpty) 'x25519_pub_key': x25519PubKey,
        if (deviceId != null) 'device_id': deviceId,
        if (displayName != null) 'display_name': displayName,
        if (avatarUrl != null) 'avatar_url': avatarUrl,
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Account &&
          accountId == other.accountId &&
          username == other.username &&
          listEquals(identityPubKey, other.identityPubKey) &&
          listEquals(x25519PubKey, other.x25519PubKey) &&
          deviceId == other.deviceId &&
          listEquals(devices, other.devices) &&
          displayName == other.displayName &&
          avatarUrl == other.avatarUrl;

  @override
  int get hashCode => Object.hash(
        accountId,
        username,
        Object.hashAll(identityPubKey),
        Object.hashAll(x25519PubKey),
        deviceId,
        Object.hashAll(devices),
        displayName,
        avatarUrl,
      );
}
