import '../../core/secure_storage/secure_storage.dart';
import 'models/app_preferences.dart';
import 'models/app_theme_mode.dart';
import 'models/disappearing_default.dart';
import 'models/text_size.dart';
import 'models/link_preview_mode.dart';
import 'models/chat_background.dart';

/// Reads/writes the user's `AppPreferences` to `SecureStorage`. Each preference
/// is stored under its own key for cheap migration + selective updates.
class AppPreferencesRepository {
  AppPreferencesRepository(this._storage);

  final SecureStorage _storage;

  static const _kThemeMode = 'pref.theme_mode';
  static const _kTextSize = 'pref.text_size';
  static const _kNotifications = 'pref.notifications_enabled';
  static const _kDisappearing = 'pref.disappearing_default';
  static const _kBiometric = 'pref.biometric_unlock';
  static const _kPasscodeEnabled = 'pref.passcode_enabled';
  static const _kBlockScreenshots = 'pref.block_screenshots';
  static const _kBlockForwarding = 'pref.block_forwarding';
  static const _kSendReadReceipts = 'pref.send_read_receipts';
  static const _kServerUrl = 'pref.server_url';
  static const _kUseTor = 'pref.use_tor';
  static const _kTorOnionUrl = 'pref.tor_onion_url';
  static const _kSocksEnabled = 'pref.socks_proxy_enabled';
  static const _kSocksHost = 'pref.socks_proxy_host';
  static const _kSocksPort = 'pref.socks_proxy_port';
  static const _kBuiltInTor = 'pref.built_in_tor_enabled';
  static const _kPushOverFcm = 'pref.push_over_fcm_enabled';
  static const _kPushPromptSeen = 'pref.push_prompt_seen';
  static const _kLinkPreviewMode = 'pref.link_preview_mode';
  static const _kChatBackground = 'pref.chat_background';
  static const _kChatBackgroundPath = 'pref.chat_background_path';

  Future<AppPreferences> load() async {
    return AppPreferences(
      themeMode: AppThemeMode.fromName(await _storage.getString(_kThemeMode)),
      textSize: TextSize.fromName(await _storage.getString(_kTextSize)),
      notificationsEnabled: _readBool(await _storage.getString(_kNotifications), defaultValue: true),
      disappearingDefault:
          _readDisappearing(await _storage.getString(_kDisappearing)),
      biometricUnlock: _readBool(await _storage.getString(_kBiometric), defaultValue: false),
      passcodeEnabled: _readBool(await _storage.getString(_kPasscodeEnabled), defaultValue: false),
      blockScreenshots: _readBool(await _storage.getString(_kBlockScreenshots), defaultValue: false),
      blockForwarding: _readBool(await _storage.getString(_kBlockForwarding), defaultValue: false),
      sendReadReceipts: _readBool(await _storage.getString(_kSendReadReceipts), defaultValue: true),
      serverUrl: await _storage.getString(_kServerUrl) ?? const AppPreferences().serverUrl,
      useTor: _readBool(await _storage.getString(_kUseTor), defaultValue: false),
      torOnionUrl: await _storage.getString(_kTorOnionUrl) ?? '',
      socksProxyEnabled:
          _readBool(await _storage.getString(_kSocksEnabled), defaultValue: false),
      socksProxyHost: await _storage.getString(_kSocksHost) ??
          const AppPreferences().socksProxyHost,
      socksProxyPort: _readInt(await _storage.getString(_kSocksPort),
          defaultValue: const AppPreferences().socksProxyPort),
      builtInTorEnabled:
          _readBool(await _storage.getString(_kBuiltInTor), defaultValue: false),
      pushOverFcmEnabled:
          _readBool(await _storage.getString(_kPushOverFcm), defaultValue: false),
      pushPromptSeen:
          _readBool(await _storage.getString(_kPushPromptSeen), defaultValue: false),
      linkPreviewMode:
          LinkPreviewMode.fromName(await _storage.getString(_kLinkPreviewMode)),
      chatBackground:
          ChatBackground.fromName(await _storage.getString(_kChatBackground)),
      chatBackgroundPath: await _storage.getString(_kChatBackgroundPath) ?? '',
    );
  }

  Future<void> save(AppPreferences prefs) async {
    await _storage.putString(_kThemeMode, prefs.themeMode.name);
    await _storage.putString(_kTextSize, prefs.textSize.name);
    await _storage.putString(_kNotifications, prefs.notificationsEnabled.toString());
    await _storage.putString(_kDisappearing, prefs.disappearingDefault.name);
    await _storage.putString(_kBiometric, prefs.biometricUnlock.toString());
    await _storage.putString(_kPasscodeEnabled, prefs.passcodeEnabled.toString());
    await _storage.putString(_kBlockScreenshots, prefs.blockScreenshots.toString());
    await _storage.putString(_kBlockForwarding, prefs.blockForwarding.toString());
    await _storage.putString(_kSendReadReceipts, prefs.sendReadReceipts.toString());
    await _storage.putString(_kServerUrl, prefs.serverUrl);
    await _storage.putString(_kUseTor, prefs.useTor.toString());
    await _storage.putString(_kTorOnionUrl, prefs.torOnionUrl);
    await _storage.putString(_kSocksEnabled, prefs.socksProxyEnabled.toString());
    await _storage.putString(_kSocksHost, prefs.socksProxyHost);
    await _storage.putString(_kSocksPort, prefs.socksProxyPort.toString());
    await _storage.putString(_kBuiltInTor, prefs.builtInTorEnabled.toString());
    await _storage.putString(_kPushOverFcm, prefs.pushOverFcmEnabled.toString());
    await _storage.putString(_kPushPromptSeen, prefs.pushPromptSeen.toString());
    await _storage.putString(_kLinkPreviewMode, prefs.linkPreviewMode.name);
    await _storage.putString(_kChatBackground, prefs.chatBackground.name);
    await _storage.putString(_kChatBackgroundPath, prefs.chatBackgroundPath);
  }

  bool _readBool(String? raw, {required bool defaultValue}) {
    if (raw == null) return defaultValue;
    return raw == 'true';
  }

  int _readInt(String? raw, {required int defaultValue}) {
    if (raw == null) return defaultValue;
    return int.tryParse(raw) ?? defaultValue;
  }

  /// Nothing persisted → the model default (one week). A persisted-but-
  /// unknown name (e.g. the legacy 'off') keeps fromName's thirtyDays
  /// fallback — closest to what those users had chosen.
  DisappearingDefault _readDisappearing(String? raw) {
    if (raw == null) return const AppPreferences().disappearingDefault;
    return DisappearingDefault.fromName(raw);
  }
}
