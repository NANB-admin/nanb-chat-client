import '../../../core/models/device.dart';
import '../models/own_device_gap.dart';

/// Compares a group's real members with this account's active devices. Pure and
/// deterministic: every member device feeds in the same data and gets the same
/// order. Only ever looks at OUR OWN account, so nothing here adds a device on
/// the word of the peer's directory.
class OwnDeviceGapFinder {
  const OwnDeviceGapFinder._();

  /// The gap in a group with [memberDeviceIds], or null when there is nothing to
  /// do: no device is missing, or this device isn't a member and so can't add
  /// anyone.
  static OwnDeviceGap? find({
    required Set<String> memberDeviceIds,
    required Iterable<Device> myDevices,
    required String myDeviceId,
  }) {
    if (!memberDeviceIds.contains(myDeviceId)) return null;
    final missing = [
      for (final d in myDevices)
        if (!memberDeviceIds.contains(d.deviceId)) d,
    ];
    if (missing.isEmpty) return null;
    final ownMembers = [
      for (final d in myDevices)
        if (memberDeviceIds.contains(d.deviceId)) d.deviceId,
    ]..sort();
    final rank = ownMembers.indexOf(myDeviceId);
    return OwnDeviceGap(missing: missing, rank: rank < 0 ? 0 : rank);
  }
}
