import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/core/models/device.dart';
import 'package:nanb_chat/features/chat/services/own_device_gap_finder.dart';

Device _device(String id) =>
    Device(deviceId: id, accountId: 'me', devicePubKey: const []);

void main() {
  test('nothing to do when every device is in the group', () {
    final gap = OwnDeviceGapFinder.find(
      memberDeviceIds: {'a', 'b', 'peer'},
      myDevices: [_device('a'), _device('b')],
      myDeviceId: 'a',
    );
    expect(gap, isNull);
  });

  test('a device outside the group has nothing to do', () {
    final gap = OwnDeviceGapFinder.find(
      memberDeviceIds: {'b', 'peer'},
      myDevices: [_device('a'), _device('b')],
      myDeviceId: 'a',
    );
    expect(gap, isNull);
  });

  test('names the devices that are missing', () {
    final gap = OwnDeviceGapFinder.find(
      memberDeviceIds: {'a', 'peer'},
      myDevices: [_device('a'), _device('b'), _device('c')],
      myDeviceId: 'a',
    );
    expect(gap!.missing.map((d) => d.deviceId), ['b', 'c']);
  });

  test('the lowest own member goes first', () {
    final gap = OwnDeviceGapFinder.find(
      memberDeviceIds: {'a', 'b', 'peer'},
      myDevices: [_device('b'), _device('a'), _device('c')],
      myDeviceId: 'a',
    );
    expect(gap!.rank, 0);
  });

  test('a higher own member waits behind the lower ones', () {
    final gap = OwnDeviceGapFinder.find(
      memberDeviceIds: {'a', 'b', 'peer'},
      myDevices: [_device('a'), _device('b'), _device('c')],
      myDeviceId: 'b',
    );
    expect(gap!.rank, 1);
  });

  test("the peer's devices never affect the order", () {
    final gap = OwnDeviceGapFinder.find(
      memberDeviceIds: {'0-peer', 'b', 'peer'},
      myDevices: [_device('b'), _device('c')],
      myDeviceId: 'b',
    );
    expect(gap!.rank, 0);
  });

  test('a removed device still listed in the group does not hold up the order',
      () {
    final gap = OwnDeviceGapFinder.find(
      memberDeviceIds: {'0-revoked', 'b', 'peer'},
      myDevices: [_device('b'), _device('c')],
      myDeviceId: 'b',
    );
    expect(gap!.rank, 0);
  });
}
