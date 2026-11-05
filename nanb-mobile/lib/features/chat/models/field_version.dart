import 'package:flutter/foundation.dart';

/// The last-writer-wins version of one synced per-chat field: when it was
/// written (ms) and by which device. Compared by [timestampMs] first, then
/// [deviceId] lexicographically as the tie-break, so every device picks the
/// same winner.
@immutable
class FieldVersion {
  const FieldVersion(this.timestampMs, this.deviceId);

  final int timestampMs;
  final String deviceId;

  /// True when this version beats [other]. A missing version loses to anything.
  bool isNewerThan(FieldVersion? other) {
    if (other == null) return true;
    if (timestampMs != other.timestampMs) {
      return timestampMs > other.timestampMs;
    }
    return deviceId.compareTo(other.deviceId) > 0;
  }

  @override
  bool operator ==(Object other) =>
      other is FieldVersion &&
      other.timestampMs == timestampMs &&
      other.deviceId == deviceId;

  @override
  int get hashCode => Object.hash(timestampMs, deviceId);

  @override
  String toString() => 'FieldVersion($timestampMs, $deviceId)';
}
