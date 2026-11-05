import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:nanb_chat/app/providers.dart';
import 'package:nanb_chat/core/auth/app_lock_controller.dart';
import 'package:nanb_chat/core/auth/app_lock_service.dart';
import 'package:nanb_chat/core/secure_storage/secure_storage.dart';
import 'package:nanb_chat/features/app_lock/app_lock_gate.dart';
import 'package:nanb_chat/features/settings/app_preferences_notifier.dart';
import 'package:nanb_chat/features/settings/app_preferences_repository.dart';

class _FakeLockService implements AppLockService {
  _FakeLockService({this.authResult = true});
  bool authResult;
  int authCalls = 0;

  @override
  Future<bool> canAuthenticate() async => true;

  @override
  Future<bool> authenticate({required String reason}) async {
    authCalls++;
    return authResult;
  }
}

/// Builds the gate with a pre-loaded preferences notifier (so `enabled` is
/// settled synchronously before the first frame).
Future<void> _pumpGate(
  WidgetTester tester, {
  required bool biometricEnabled,
  required AppLockService service,
  required AppLockController controller,
}) async {
  final storage = SecureStorageInMemory();
  if (biometricEnabled) {
    await storage.putString('pref.biometric_unlock', 'true');
  }
  final prefs = AppPreferencesNotifier(AppPreferencesRepository(storage));
  await prefs.load();

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appPreferencesProvider.overrideWith((_) => prefs),
        appLockServiceProvider.overrideWithValue(service),
        appLockControllerProvider.overrideWith((_) => controller),
      ],
      child: const MaterialApp(home: AppLockGate(child: Text('SECRET'))),
    ),
  );
  await tester.pumpAndSettle();
}

/// Drives a foreground transition so the lock screen runs its biometric prompt.
Future<void> _resume(WidgetTester tester) async {
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  await tester.pumpAndSettle();
}

void main() {
  group('AppLockController', () {
    test('starts locked', () {
      expect(AppLockController().isLocked, isTrue);
    });

    test('unlock then lock toggles and notifies only on change', () {
      final c = AppLockController();
      var notifications = 0;
      c.addListener(() => notifications++);

      c.unlock();
      expect(c.isLocked, isFalse);
      expect(notifications, 1);

      c.unlock(); // already unlocked — no-op
      expect(notifications, 1);

      c.lock();
      expect(c.isLocked, isTrue);
      expect(notifications, 2);
    });

    test('suppressNextBackgroundLock makes a background lock a no-op', () {
      final c = AppLockController();
      c.unlock();
      c.suppressNextBackgroundLock(); // about to launch the camera/picker
      c.lock(); // the resulting background must NOT lock
      expect(c.isLocked, isFalse);
    });

    test('resumeFromBackground keeps it unlocked after a brief excursion', () {
      var now = DateTime(2026, 6, 30, 12, 0, 0);
      final c = AppLockController(now: () => now);
      c.unlock();
      c.suppressNextBackgroundLock();
      c.lock(); // suppressed
      now = now.add(const Duration(seconds: 5)); // quick camera hop
      c.resumeFromBackground();
      expect(c.isLocked, isFalse);
    });

    test('resumeFromBackground re-locks after an over-long excursion', () {
      var now = DateTime(2026, 6, 30, 12, 0, 0);
      final c = AppLockController(now: () => now);
      c.unlock();
      c.suppressNextBackgroundLock();
      c.lock(); // suppressed
      now = now.add(const Duration(minutes: 10)); // wandered off, not a quick hop
      c.resumeFromBackground();
      expect(c.isLocked, isTrue);
    });

    test('a normal background locks again after the excursion ends', () {
      var now = DateTime(2026, 6, 30, 12, 0, 0);
      final c = AppLockController(now: () => now);
      c.unlock();
      c.suppressNextBackgroundLock();
      c.lock();
      now = now.add(const Duration(seconds: 5));
      c.resumeFromBackground(); // brief → unlocked + suppression cleared
      expect(c.isLocked, isFalse);
      c.lock(); // a later, real background
      expect(c.isLocked, isTrue);
    });
  });

  group('AppLockGate', () {
    testWidgets('does not lock when the preference is off', (tester) async {
      await _pumpGate(
        tester,
        biometricEnabled: false,
        service: _FakeLockService(),
        controller: AppLockController(), // locked, but feature is off
      );
      expect(find.text('Locked'), findsNothing);
    });

    testWidgets('shows the lock screen when enabled and locked', (tester) async {
      await _pumpGate(
        tester,
        biometricEnabled: true,
        service: _FakeLockService(authResult: false),
        controller: AppLockController(),
      );
      expect(find.text('Locked'), findsOneWidget);
    });

    testWidgets('successful auth removes the lock', (tester) async {
      final service = _FakeLockService(authResult: true);
      await _pumpGate(
        tester,
        biometricEnabled: true,
        service: service,
        controller: AppLockController(),
      );

      await _resume(tester); // foreground → auto-prompt → success

      expect(service.authCalls, greaterThanOrEqualTo(1));
      expect(find.text('Locked'), findsNothing);
    });

    testWidgets('failed auth keeps the lock up', (tester) async {
      await _pumpGate(
        tester,
        biometricEnabled: true,
        service: _FakeLockService(authResult: false),
        controller: AppLockController(),
      );

      await _resume(tester); // foreground → auto-prompt → failure

      expect(find.text('Locked'), findsOneWidget);
      expect(find.textContaining('failed'), findsOneWidget);
    });
  });
}
