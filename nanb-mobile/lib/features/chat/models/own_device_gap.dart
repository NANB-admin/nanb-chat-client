import '../../../core/models/device.dart';

/// Which of this account's devices a group is missing, and this device's place
/// in the order of who should add them.
class OwnDeviceGap {
  const OwnDeviceGap({required this.missing, required this.rank});

  /// Active devices of this account that are not in the group.
  final List<Device> missing;

  /// 0 means this device acts first. Higher ranks wait for the ones before them,
  /// so two devices don't commit the same add and fork the group.
  final int rank;
}
