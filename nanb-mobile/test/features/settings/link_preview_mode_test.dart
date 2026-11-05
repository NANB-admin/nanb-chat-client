import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/core/secure_storage/secure_storage.dart';
import 'package:nanb_chat/features/settings/app_preferences_repository.dart';
import 'package:nanb_chat/features/settings/models/app_preferences.dart';
import 'package:nanb_chat/features/settings/models/link_preview_mode.dart';

class _MemoryStorage implements SecureStorage {
  final values = <String, String>{};

  @override
  Future<String?> getString(String key) async => values[key];
  @override
  Future<void> putString(String key, String value) async =>
      values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
  @override
  Future<void> clear() async => values.clear();
}

void main() {
  group('LinkPreviewMode', () {
    test('defaults to Tor-only', () {
      expect(const AppPreferences().linkPreviewMode, LinkPreviewMode.viaTor);
    });

    test('fromName parses each name', () {
      expect(LinkPreviewMode.fromName('off'), LinkPreviewMode.off);
      expect(LinkPreviewMode.fromName('always'), LinkPreviewMode.always);
    });

    test('fromName falls back to Tor-only on null or unknown', () {
      expect(LinkPreviewMode.fromName(null), LinkPreviewMode.viaTor);
      expect(LinkPreviewMode.fromName('bogus'), LinkPreviewMode.viaTor);
    });

    test('is persisted and read back', () async {
      final repo = AppPreferencesRepository(_MemoryStorage());
      await repo.save(
          const AppPreferences(linkPreviewMode: LinkPreviewMode.always));

      expect((await repo.load()).linkPreviewMode, LinkPreviewMode.always);
    });

    test('a fresh install loads the default', () async {
      final repo = AppPreferencesRepository(_MemoryStorage());

      expect((await repo.load()).linkPreviewMode, LinkPreviewMode.viaTor);
    });

    test('is part of preference equality', () {
      expect(
        const AppPreferences(linkPreviewMode: LinkPreviewMode.off),
        isNot(const AppPreferences(linkPreviewMode: LinkPreviewMode.always)),
      );
    });
  });
}
