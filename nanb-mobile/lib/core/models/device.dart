import 'package:flutter/foundation.dart';

import 'device_kind.dart';
import 'json_bytes.dart';

@immutable
class Device {
  const Device({
    required this.deviceId,
    required this.accountId,
    required this.devicePubKey,
    this.x25519PubKey = const [],
    this.displayName,
    this.linkedAt,
    this.isThisDevice = false,
    this.supportsSealed = false,
    this.kind = DeviceKind.phone,
    this.linkedByDeviceId,
    this.expiresAt,
  });

  final String deviceId;
  final String accountId;
  final List<int> devicePubKey;

  /// The device's own X25519 key — used to seed a per-device ratchet for
  /// multi-device self-sync. Empty for older servers / accounts.
  final List<int> x25519PubKey;

  final String? displayName;
  final DateTime? linkedAt;

  /// True when this row corresponds to the device the JWT was issued for.
  /// Set by `GET /devices` based on the JWT's device_id claim.
  final bool isThisDevice;

  /// Whether this device advertised it can OPEN sealed-sender envelopes.
  /// Gates self-sync sealing so a sibling device on an old build isn't
  /// stranded with an undecryptable copy. Defaults false (conservative).
  final bool supportsSealed;

  /// "phone" or "web". Absent on an older server => phone.
  final DeviceKind kind;

  /// The device that authorized this one's link; null for the first device or
  /// a legacy row. Drives which existing device adds this one to MLS groups.
  final String? linkedByDeviceId;

  /// When this device's link lapses (web devices); null = never.
  final DateTime? expiresAt;

  factory Device.fromJson(Map<String, dynamic> json) => Device(
        deviceId: json['device_id'] as String,
        accountId: json['account_id'] as String,
        devicePubKey: bytesFromJson(json['device_pub_key']),
        x25519PubKey: bytesFromJson(json['x25519_pub_key']),
        displayName: json['display_name'] as String?,
        linkedAt: json['linked_at'] != null
            ? DateTime.parse(json['linked_at'] as String)
            : null,
        isThisDevice: (json['is_this_device'] as bool?) ?? false,
        supportsSealed: json['supports_sealed'] as bool? ?? false,
        kind: DeviceKind.fromWire(json['kind'] as String?),
        linkedByDeviceId: json['linked_by_device_id'] as String?,
        expiresAt: json['expires_at'] != null
            ? DateTime.parse(json['expires_at'] as String)
            : null,
      );

  Map<String, dynamic> toJson() => {
        'device_id': deviceId,
        'account_id': accountId,
        'device_pub_key': devicePubKey,
        if (displayName != null) 'display_name': displayName,
        if (linkedAt != null) 'linked_at': linkedAt!.toUtc().toIso8601String(),
        'is_this_device': isThisDevice,
        'kind': kind.wire,
        if (linkedByDeviceId != null) 'linked_by_device_id': linkedByDeviceId,
        if (expiresAt != null) 'expires_at': expiresAt!.toUtc().toIso8601String(),
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Device &&
          deviceId == other.deviceId &&
          accountId == other.accountId &&
          listEquals(devicePubKey, other.devicePubKey) &&
          displayName == other.displayName &&
          linkedAt == other.linkedAt &&
          isThisDevice == other.isThisDevice &&
          supportsSealed == other.supportsSealed &&
          kind == other.kind &&
          linkedByDeviceId == other.linkedByDeviceId &&
          expiresAt == other.expiresAt;

  @override
  int get hashCode => Object.hash(
        deviceId,
        accountId,
        Object.hashAll(devicePubKey),
        displayName,
        linkedAt,
        isThisDevice,
        supportsSealed,
        kind,
        linkedByDeviceId,
        expiresAt,
      );
}
