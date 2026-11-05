import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/core/models/device.dart';
import 'package:nanb_chat/features/chat/services/adder_election.dart';

Device _d(String id, {String? linkedBy}) => Device(
      deviceId: id,
      accountId: 'acc',
      devicePubKey: const [],
      linkedByDeviceId: linkedBy,
    );

void main() {
  test('picks the device that linked the newcomer when it is active', () {
    final newcomer = _d('new', linkedBy: 'zzz');
    final adder = AdderElection.adderFor(
      newDevice: newcomer,
      activeDevices: [_d('aaa'), _d('zzz'), newcomer],
      newDeviceIds: {'new'},
    );
    expect(adder, 'zzz');
  });

  test('falls back to the smallest old id when linkedBy is null', () {
    final newcomer = _d('new');
    final adder = AdderElection.adderFor(
      newDevice: newcomer,
      activeDevices: [_d('mmm'), _d('bbb'), newcomer],
      newDeviceIds: {'new'},
    );
    expect(adder, 'bbb');
  });

  test('falls back to the smallest old id when linkedBy is not active', () {
    final newcomer = _d('new', linkedBy: 'gone');
    final adder = AdderElection.adderFor(
      newDevice: newcomer,
      activeDevices: [_d('mmm'), _d('bbb'), newcomer],
      newDeviceIds: {'new'},
    );
    expect(adder, 'bbb');
  });

  test('a linker that is itself new this sweep cannot be the adder', () {
    final linker = _d('new-a', linkedBy: 'bbb');
    final newcomer = _d('new-b', linkedBy: 'new-a');
    final adder = AdderElection.adderFor(
      newDevice: newcomer,
      activeDevices: [_d('bbb'), linker, newcomer],
      newDeviceIds: {'new-a', 'new-b'},
    );
    expect(adder, 'bbb');
  });

  test('is null when there is no pre-existing device', () {
    final newcomer = _d('new');
    final adder = AdderElection.adderFor(
      newDevice: newcomer,
      activeDevices: [newcomer],
      newDeviceIds: {'new'},
    );
    expect(adder, isNull);
  });

  test('every device computes the same answer from the same list', () {
    final newcomer = _d('new', linkedBy: 'ccc');
    final list = [_d('ccc'), _d('aaa'), newcomer];
    final first = AdderElection.adderFor(
        newDevice: newcomer, activeDevices: list, newDeviceIds: {'new'});
    final second = AdderElection.adderFor(
        newDevice: newcomer,
        activeDevices: list.reversed,
        newDeviceIds: {'new'});
    expect(second, first);
  });
}
