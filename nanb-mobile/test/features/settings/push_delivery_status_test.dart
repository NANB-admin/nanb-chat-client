import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/core/push/push_permission.dart';
import 'package:nanb_chat/features/settings/models/push_blocker.dart';
import 'package:nanb_chat/features/settings/models/push_delivery_status.dart';

PushDeliveryStatus status({
  bool app = true,
  bool fcm = true,
  PushPermission permission = PushPermission.granted,
  bool? token = true,
}) =>
    PushDeliveryStatus(
      appNotificationsEnabled: app,
      pushOverFcmEnabled: fcm,
      permission: permission,
      hasServerToken: token,
    );

void main() {
  group('PushDeliveryStatus.blocker', () {
    test('is none when every gate is satisfied', () {
      expect(status().blocker, PushBlocker.none);
    });

    test('reports the in-app notifications toggle first', () {
      expect(status(app: false).blocker, PushBlocker.appNotificationsOff);
    });

    test('reports push-over-FCM when the notifications toggle is on', () {
      expect(status(fcm: false).blocker, PushBlocker.pushOverFcmOff);
    });

    test('reports the earliest gate when several are off at once', () {
      // The later gates only LOOK broken because an earlier one is off, so
      // naming a later one would send the user to fix the wrong thing.
      final s = status(
        app: false,
        fcm: false,
        permission: PushPermission.denied,
        token: false,
      );
      expect(s.blocker, PushBlocker.appNotificationsOff);
    });

    test('reports a denied OS permission once both toggles are on', () {
      expect(status(permission: PushPermission.denied).blocker,
          PushBlocker.osPermissionDenied);
    });

    test('reports an unasked OS permission separately from a denied one', () {
      // Different remedies: unasked can still be prompted in-app, denied
      // cannot (iOS never shows the system prompt twice).
      expect(status(permission: PushPermission.notDetermined).blocker,
          PushBlocker.osPermissionNotAsked);
    });

    test('does not blame the OS when the permission could not be read', () {
      // `unknown` means Firebase was unreadable, not that the user refused.
      expect(status(permission: PushPermission.unknown).blocker,
          PushBlocker.none);
    });

    test('reports a missing server token when everything else is on', () {
      expect(status(token: false).blocker, PushBlocker.noTokenRegistered);
    });

    test('treats an unattempted registration as not-yet-known, not a failure',
        () {
      // Null = no registration attempted this session. Rendering that as
      // broken would make a healthy device look dead on every cold start.
      expect(status(token: null).blocker, PushBlocker.none);
    });

    test('provisional-style granted permission is deliverable', () {
      expect(status(permission: PushPermission.granted).deliverable, isTrue);
    });
  });
}
