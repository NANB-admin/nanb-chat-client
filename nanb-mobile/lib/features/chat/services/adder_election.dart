import '../../../core/models/device.dart';

/// Decides which ONE of our existing devices adds a freshly-linked own device
/// to the account's MLS conversations. Pure and deterministic: every device
/// feeds in the same device list and must get the same answer, otherwise two
/// devices would both add the newcomer and fork the group.
///
/// Rule for new device X:
///  1. X.linkedByDeviceId, if that device is in the active list AND is itself
///     a pre-existing device (not also new this sweep — a brand-new device may
///     not be a member of any group yet, so it cannot add anyone);
///  2. otherwise the lexically smallest pre-existing device id.
class AdderElection {
  const AdderElection._();

  /// The device id that should add [newDevice], or null when there is no
  /// pre-existing device at all.
  ///
  /// [activeDevices] is the full current device list; [newDeviceIds] is the
  /// subset that is new since the last baseline.
  static String? adderFor({
    required Device newDevice,
    required Iterable<Device> activeDevices,
    required Set<String> newDeviceIds,
  }) {
    final oldIds = [
      for (final d in activeDevices)
        if (!newDeviceIds.contains(d.deviceId)) d.deviceId,
    ]..sort();
    final linkedBy = newDevice.linkedByDeviceId;
    if (linkedBy != null && oldIds.contains(linkedBy)) return linkedBy;
    return oldIds.isEmpty ? null : oldIds.first;
  }
}
