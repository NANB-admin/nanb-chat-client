import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/core/push/local_notifications.dart';
import 'package:nanb_chat/core/push/notification_tap_router.dart';

class _FakeNotifications implements LocalNotifications {
  _FakeNotifications({this.launchPayload});

  /// If non-null, [init] emits this onto the tap stream — simulating a
  /// cold-start launch where the user tapped the notification to open the
  /// app.
  final String? launchPayload;

  final _tapCtl = StreamController<String>.broadcast();
  bool initCalled = false;

  @override
  Stream<String> get conversationTaps => _tapCtl.stream;

  @override
  Future<void> cancelAll() async {}

  @override
  Future<void> init() async {
    initCalled = true;
    if (launchPayload != null) {
      _tapCtl.add(launchPayload!);
    }
  }

  @override
  Future<void> show({
    required int id,
    required String title,
    required String body,
    required String conversationId,
  }) async {}

  @override
  Future<void> showCall({
    required int id,
    required String caller,
    required String conversationId,
  }) async {}

  @override
  Future<void> cancel(int id) async {}

  @override
  Future<bool> requestFullScreenIntentPermission() async => true;

  void emit(String convoId) => _tapCtl.add(convoId);

  Future<void> close() => _tapCtl.close();
}

void main() {
  group('NotificationTapRouter', () {
    test('start() invokes notifications.init()', () async {
      final fake = _FakeNotifications();
      final router = NotificationTapRouter(
        notifications: fake,
        onTap: (_) {},
      );
      await router.start();
      expect(fake.initCalled, isTrue);
    });

    test('warm tap after start triggers onTap with the conversation id',
        () async {
      final fake = _FakeNotifications();
      final taps = <String>[];
      final router = NotificationTapRouter(
        notifications: fake,
        onTap: taps.add,
      );
      await router.start();
      fake.emit('group:abc');
      await Future<void>.delayed(Duration.zero);
      expect(taps, ['group:abc']);
      await fake.close();
    });

    test('cold-start launch payload reaches onTap', () async {
      final fake = _FakeNotifications(launchPayload: 'one-to-one:42');
      final taps = <String>[];
      final router = NotificationTapRouter(
        notifications: fake,
        onTap: taps.add,
      );
      await router.start();
      await Future<void>.delayed(Duration.zero);
      expect(taps, ['one-to-one:42']);
      await fake.close();
    });

    test('dispose stops delivering taps to onTap', () async {
      final fake = _FakeNotifications();
      final taps = <String>[];
      final router = NotificationTapRouter(
        notifications: fake,
        onTap: taps.add,
      );
      await router.start();
      await router.dispose();
      fake.emit('group:after-dispose');
      await Future<void>.delayed(Duration.zero);
      expect(taps, isEmpty);
      await fake.close();
    });

    test('start() is idempotent — second call does not double-subscribe',
        () async {
      final fake = _FakeNotifications();
      final taps = <String>[];
      final router = NotificationTapRouter(
        notifications: fake,
        onTap: taps.add,
      );
      await router.start();
      await router.start();
      fake.emit('group:once');
      await Future<void>.delayed(Duration.zero);
      expect(taps, ['group:once'], reason: 'tap should be delivered exactly once');
      await fake.close();
    });
  });
}
