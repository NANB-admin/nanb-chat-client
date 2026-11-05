import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/core/secure_storage/secure_storage.dart';
import 'package:nanb_chat/features/settings/app_preferences_notifier.dart';
import 'package:nanb_chat/features/settings/app_preferences_repository.dart';
import 'package:nanb_chat/features/settings/models/app_preferences.dart';
import 'package:nanb_chat/features/settings/models/app_theme_mode.dart';
import 'package:nanb_chat/features/settings/models/disappearing_default.dart';
import 'package:nanb_chat/features/settings/models/text_size.dart';

/// SecureStorage whose reads always throw — exercises the notifier's
/// load() fallback (hydrate-with-defaults instead of staying unhydrated).
class _ThrowingStorage implements SecureStorage {
  @override
  Future<String?> getString(String key) async =>
      throw StateError('keystore unavailable');
  @override
  Future<void> putString(String key, String value) async {}
  @override
  Future<void> delete(String key) async {}
  @override
  Future<void> clear() async {}
}

void main() {
  group('AppThemeMode.fromName', () {
    test('parses each known name', () {
      expect(AppThemeMode.fromName('system'), equals(AppThemeMode.system));
      expect(AppThemeMode.fromName('light'), equals(AppThemeMode.light));
      expect(AppThemeMode.fromName('dark'), equals(AppThemeMode.dark));
    });

    test('falls back to system on null or unknown', () {
      expect(AppThemeMode.fromName(null), equals(AppThemeMode.system));
      expect(AppThemeMode.fromName('purple'), equals(AppThemeMode.system));
    });
  });

  group('TextSize', () {
    test('fromName parses names + falls back to medium', () {
      expect(TextSize.fromName('small'), equals(TextSize.small));
      expect(TextSize.fromName('large'), equals(TextSize.large));
      expect(TextSize.fromName(null), equals(TextSize.medium));
      expect(TextSize.fromName('huge'), equals(TextSize.medium));
    });

    test('medium is the 1.0 baseline; small < 1 < large', () {
      expect(TextSize.medium.scale, equals(1.0));
      expect(TextSize.small.scale, lessThan(1.0));
      expect(TextSize.large.scale, greaterThan(1.0));
    });
  });

  group('DisappearingDefault', () {
    test('fromName parses names + falls back to thirtyDays', () {
      expect(DisappearingDefault.fromName('oneDay'), equals(DisappearingDefault.oneDay));
      expect(DisappearingDefault.fromName(null), equals(DisappearingDefault.thirtyDays));
      expect(DisappearingDefault.fromName('garbage'), equals(DisappearingDefault.thirtyDays));
      // Legacy builds had an 'off' option; stored prefs migrate to the cap.
      expect(DisappearingDefault.fromName('off'), equals(DisappearingDefault.thirtyDays));
    });

    test('there is no off option — messages always expire', () {
      expect(DisappearingDefault.values.map((d) => d.name), isNot(contains('off')));
    });

    test('label maps each value', () {
      expect(DisappearingDefault.oneDay.label, equals('24 hours'));
      expect(DisappearingDefault.oneWeek.label, equals('1 week'));
      expect(DisappearingDefault.thirtyDays.label, equals('30 days'));
    });
  });

  group('AppPreferences', () {
    test('default values match the design defaults', () {
      const p = AppPreferences();
      expect(p.themeMode, equals(AppThemeMode.system));
      expect(p.textSize, equals(TextSize.medium));
      expect(p.notificationsEnabled, isTrue);
      expect(p.disappearingDefault, equals(DisappearingDefault.oneWeek));
      expect(p.biometricUnlock, isFalse);
      expect(p.serverUrl, equals('https://nanb.link'));
      expect(p.useTor, isFalse);
      expect(p.socksProxyEnabled, isFalse);
      expect(p.socksProxyHost, equals('127.0.0.1'));
      expect(p.socksProxyPort, equals(9050));
      // FCM push defaults OFF — opt-in (privacy by default); the first-launch
      // prompt / Settings turns it on.
      expect(p.pushOverFcmEnabled, isFalse);
      expect(p.pushPromptSeen, isFalse);
    });

    test('built-in Tor defaults OFF — opt-in, so a fresh install connects '
        'over clearnet until the user turns it on', () {
      expect(const AppPreferences().builtInTorEnabled, isFalse);
    });

    test('copyWith updates only provided fields', () {
      const base = AppPreferences();
      final next = base.copyWith(themeMode: AppThemeMode.dark, useTor: true);
      expect(next.themeMode, equals(AppThemeMode.dark));
      expect(next.useTor, isTrue);
      expect(next.notificationsEnabled, equals(base.notificationsEnabled));
      expect(next.serverUrl, equals(base.serverUrl));
    });

    test('equality + hashCode consider every field', () {
      const a = AppPreferences();
      const b = AppPreferences();
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));

      final c = a.copyWith(themeMode: AppThemeMode.dark);
      expect(a, isNot(equals(c)));
    });
  });

  group('AppPreferencesRepository', () {
    late SecureStorageInMemory storage;
    late AppPreferencesRepository repo;

    setUp(() {
      storage = SecureStorageInMemory();
      repo = AppPreferencesRepository(storage);
    });

    test('returns defaults when storage is empty', () async {
      final p = await repo.load();
      expect(p, equals(const AppPreferences()));
    });

    test('nothing persisted for built-in Tor loads as OFF', () async {
      final p = await repo.load();
      expect(p.builtInTorEnabled, isFalse);
    });

    test('persists and reloads every field', () async {
      const next = AppPreferences(
        themeMode: AppThemeMode.dark,
        textSize: TextSize.large,
        notificationsEnabled: false,
        disappearingDefault: DisappearingDefault.oneWeek,
        biometricUnlock: true,
        serverUrl: 'https://example.com',
        useTor: true,
        torOnionUrl: 'http://abc.onion:8080',
        socksProxyEnabled: true,
        socksProxyHost: '10.0.0.5',
        socksProxyPort: 9150,
        pushOverFcmEnabled: false,
      );
      await repo.save(next);

      final loaded = await repo.load();
      expect(loaded, equals(next));
    });

    test('treats malformed boolean as false', () async {
      await storage.putString('pref.notifications_enabled', 'maybe');
      final loaded = await repo.load();
      expect(loaded.notificationsEnabled, isFalse);
    });

    test('treats malformed socks port as the default', () async {
      await storage.putString('pref.socks_proxy_port', 'not-a-number');
      final loaded = await repo.load();
      expect(loaded.socksProxyPort, equals(9050));
    });
  });

  group('AppPreferencesNotifier', () {
    late SecureStorageInMemory storage;
    late AppPreferencesNotifier notifier;

    setUp(() {
      storage = SecureStorageInMemory();
      notifier = AppPreferencesNotifier(AppPreferencesRepository(storage));
    });

    test('starts unhydrated with defaults', () {
      expect(notifier.hydrated, isFalse);
      expect(notifier.value, equals(const AppPreferences()));
    });

    test('load() still marks hydrated when the store throws — falls back to '
        'defaults so the fail-closed SOCKS hold can never strand the app',
        () async {
      final throwing =
          AppPreferencesNotifier(AppPreferencesRepository(_ThrowingStorage()));
      await throwing.load();
      expect(throwing.hydrated, isTrue);
      expect(throwing.value, equals(const AppPreferences()));
    });

    test('hydrateFrom seeds a preloaded snapshot synchronously (hydrated, '
        'so the transport is known before the first connection)', () {
      const seeded = AppPreferences(builtInTorEnabled: true);
      notifier.hydrateFrom(seeded);
      expect(notifier.hydrated, isTrue);
      expect(notifier.value.builtInTorEnabled, isTrue);
      // A later load() is a no-op (won't clobber the seeded value).
      // (storage is empty → would otherwise reset builtInTorEnabled to false)
    });

    test('load() drops biometric when a passcode is also set (one at a time)',
        () async {
      await storage.putString('pref.passcode_enabled', 'true');
      await storage.putString('pref.biometric_unlock', 'true');

      await notifier.load();
      expect(notifier.value.passcodeEnabled, isTrue);
      expect(notifier.value.biometricUnlock, isFalse);

      // The normalisation is persisted, so it sticks across a restart.
      final reloaded = await AppPreferencesRepository(storage).load();
      expect(reloaded.passcodeEnabled, isTrue);
      expect(reloaded.biometricUnlock, isFalse);
    });

    test('load() keeps biometric when no passcode is set', () async {
      await storage.putString('pref.biometric_unlock', 'true');
      await notifier.load();
      expect(notifier.value.biometricUnlock, isTrue);
      expect(notifier.value.passcodeEnabled, isFalse);
    });

    test('load() hydrates from storage and is idempotent', () async {
      await storage.putString('pref.theme_mode', 'dark');
      await notifier.load();
      expect(notifier.hydrated, isTrue);
      expect(notifier.value.themeMode, equals(AppThemeMode.dark));

      // Mutate storage out-of-band; second load is a no-op.
      await storage.putString('pref.theme_mode', 'light');
      await notifier.load();
      expect(notifier.value.themeMode, equals(AppThemeMode.dark));
    });

    test('setThemeMode persists and notifies', () async {
      var notifyCount = 0;
      notifier.addListener(() => notifyCount++);
      await notifier.setThemeMode(AppThemeMode.dark);
      expect(notifier.value.themeMode, equals(AppThemeMode.dark));
      expect(await storage.getString('pref.theme_mode'), equals('dark'));
      expect(notifyCount, equals(1));
    });

    test('setting the same value is a no-op (no notify, no write)', () async {
      var notifyCount = 0;
      notifier.addListener(() => notifyCount++);
      await notifier.setNotificationsEnabled(true); // default is true
      expect(notifyCount, equals(0));
    });

    test('every setter persists its field', () async {
      await notifier.setNotificationsEnabled(false);
      await notifier.setDisappearingDefault(DisappearingDefault.oneDay);
      await notifier.setBiometricUnlock(true);
      await notifier.setServerUrl('https://staging');
      await notifier.setUseTor(true);
      await notifier.setTorOnionUrl('http://abc.onion');
      await notifier.setSocksProxyEnabled(true);
      await notifier.setSocksProxyHost('192.168.1.2');
      await notifier.setSocksProxyPort(9150);
      await notifier.setPushOverFcmEnabled(true);
      await notifier.setPushPromptSeen(true);

      final loaded = await AppPreferencesRepository(storage).load();
      expect(loaded.notificationsEnabled, isFalse);
      expect(loaded.pushOverFcmEnabled, isTrue);
      expect(loaded.pushPromptSeen, isTrue);
      expect(loaded.disappearingDefault, equals(DisappearingDefault.oneDay));
      expect(loaded.biometricUnlock, isTrue);
      expect(loaded.serverUrl, equals('https://staging'));
      expect(loaded.useTor, isTrue);
      expect(loaded.torOnionUrl, equals('http://abc.onion'));
      expect(loaded.socksProxyEnabled, isTrue);
      expect(loaded.socksProxyHost, equals('192.168.1.2'));
      expect(loaded.socksProxyPort, equals(9150));
    });
  });

  group('DisappearingDefault.ttl', () {
    test('oneDay/oneWeek/thirtyDays return matching durations', () {
      expect(DisappearingDefault.oneDay.ttl, equals(const Duration(days: 1)));
      expect(DisappearingDefault.oneWeek.ttl, equals(const Duration(days: 7)));
      expect(DisappearingDefault.thirtyDays.ttl, equals(const Duration(days: 30)));
    });
  });
}
