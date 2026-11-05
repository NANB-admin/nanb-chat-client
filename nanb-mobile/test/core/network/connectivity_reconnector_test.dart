import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/core/network/connectivity_reconnector.dart';

void main() {
  group('ConnectivityReconnector', () {
    late StreamController<String> controller;
    late int reconnects;
    late ConnectivityReconnector reconnector;

    setUp(() {
      controller = StreamController<String>();
      reconnects = 0;
      reconnector = ConnectivityReconnector(
        networkChanges: controller.stream,
        onNetworkRegained: () => reconnects++,
      )..start();
    });

    tearDown(() async {
      await reconnector.dispose();
      await controller.close();
    });

    // Pumps the microtask/event queue so stream events are delivered.
    Future<void> emit(String sig) async {
      controller.add(sig);
      await Future<void>.delayed(Duration.zero);
    }

    test('does not fire on the first (seed) reading', () async {
      await emit('wifi');
      expect(reconnects, 0);
    });

    test('fires on offline -> online (regained connectivity)', () async {
      await emit(ConnectivityReconnector.kOffline); // seed: offline
      await emit('wifi'); // back online
      expect(reconnects, 1);
    });

    test('fires on a WiFi <-> cellular handoff (online -> different online)',
        () async {
      await emit('wifi'); // seed
      await emit('mobile'); // handoff
      expect(reconnects, 1);
      await emit('wifi'); // handoff back
      expect(reconnects, 2);
    });

    test('does not fire when the signature is unchanged (duplicate event)',
        () async {
      await emit('wifi'); // seed
      await emit('wifi'); // duplicate
      await emit('wifi'); // duplicate
      expect(reconnects, 0);
    });

    test('does not fire when going offline', () async {
      await emit('wifi'); // seed
      await emit(ConnectivityReconnector.kOffline); // dropped
      expect(reconnects, 0);
    });

    test('offline -> online -> offline -> online fires twice', () async {
      await emit('wifi'); // seed online
      await emit(ConnectivityReconnector.kOffline);
      await emit('wifi'); // regained #1
      await emit(ConnectivityReconnector.kOffline);
      await emit('mobile'); // regained #2
      expect(reconnects, 2);
    });

    test('dispose stops further reconnects', () async {
      await emit('wifi'); // seed
      await reconnector.dispose();
      await emit('mobile');
      expect(reconnects, 0);
    });
  });

  group('networkSignature', () {
    test('maps no/empty connectivity to the offline sentinel', () {
      expect(networkSignature([]), ConnectivityReconnector.kOffline);
      expect(
        networkSignature([ConnectivityResult.none]),
        ConnectivityReconnector.kOffline,
      );
    });

    test('maps a single network to its name', () {
      expect(networkSignature([ConnectivityResult.wifi]), 'wifi');
      expect(networkSignature([ConnectivityResult.mobile]), 'mobile');
    });

    test('is order-independent for multiple networks', () {
      final a = networkSignature(
        [ConnectivityResult.wifi, ConnectivityResult.vpn],
      );
      final b = networkSignature(
        [ConnectivityResult.vpn, ConnectivityResult.wifi],
      );
      expect(a, b);
      expect(a, 'vpn+wifi');
    });

    test('ignores a none mixed in with a real network', () {
      expect(
        networkSignature([ConnectivityResult.none, ConnectivityResult.wifi]),
        'wifi',
      );
    });
  });
}
