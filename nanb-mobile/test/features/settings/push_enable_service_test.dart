import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/core/push/push_permission.dart';
import 'package:nanb_chat/features/settings/push_enable_service.dart';

/// Records the order of every step so the ordering rules can be asserted
/// without reaching into the service's internals.
class _Recorder {
  final List<String> steps = [];
  bool? appNotifications;
  bool? pushOverFcm;
  PushPermission permission = PushPermission.granted;
  bool requestThrows = false;
  bool registerThrows = false;
  bool systemSettingsOpened = false;

  PushEnableService build() => PushEnableService(
        setAppNotificationsEnabled: (v) async {
          appNotifications = v;
          steps.add('app');
        },
        setPushOverFcmEnabled: (v) async {
          pushOverFcm = v;
          steps.add('fcm');
        },
        activateFcm: () async => steps.add('activate'),
        requestPermission: () async {
          steps.add('request');
          if (requestThrows) throw StateError('firebase down');
          return permission == PushPermission.granted;
        },
        readPermission: () async => permission,
        registerToken: () async {
          steps.add('register');
          if (registerThrows) throw StateError('offline');
        },
        openSystemSettings: () async {
          systemSettingsOpened = true;
          return true;
        },
      );
}

void main() {
  group('PushEnableService.enable', () {
    test('turns on both in-app prefs', () async {
      final r = _Recorder();

      await r.build().enable();

      expect(r.appNotifications, isTrue);
      expect(r.pushOverFcm, isTrue);
    });

    test('writes both prefs before asking the OS for permission', () async {
      // The FCM providers read the prefs, so asking first would run the whole
      // sequence against the old values and mint nothing.
      final r = _Recorder();

      await r.build().enable();

      expect(r.steps.indexOf('app'), lessThan(r.steps.indexOf('request')));
      expect(r.steps.indexOf('fcm'), lessThan(r.steps.indexOf('request')));
    });

    test('brings Firebase up before requesting permission', () async {
      final r = _Recorder();

      await r.build().enable();

      expect(
          r.steps.indexOf('activate'), lessThan(r.steps.indexOf('request')));
    });

    test('registers the token even when permission was refused', () async {
      // Android can still hold a token and receive data wakeups, and
      // re-registering repairs a token the server rejected earlier.
      final r = _Recorder()..permission = PushPermission.denied;

      await r.build().enable();

      expect(r.steps, contains('register'));
    });

    test('still registers when the permission request throws', () async {
      final r = _Recorder()..requestThrows = true;

      await r.build().enable();

      expect(r.steps, contains('register'));
    });

    test('reports the refusal so the caller can offer system settings',
        () async {
      final r = _Recorder()..permission = PushPermission.denied;

      expect(await r.build().enable(), PushPermission.denied);
    });

    test('survives a failed token registration', () async {
      // Best-effort by design: the next connect re-POSTs.
      final r = _Recorder()..registerThrows = true;

      expect(await r.build().enable(), PushPermission.granted);
    });

    test('openSystemSettings delegates to the platform', () async {
      final r = _Recorder();

      await r.build().openSystemSettings();

      expect(r.systemSettingsOpened, isTrue);
    });
  });
}
