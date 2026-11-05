import 'package:flutter/foundation.dart';

import 'app_preferences_repository.dart';
import 'models/app_preferences.dart';
import 'models/app_theme_mode.dart';
import 'models/disappearing_default.dart';
import 'models/text_size.dart';
import 'models/link_preview_mode.dart';
import 'models/chat_background.dart';

/// Holds the current `AppPreferences` in memory + persists every mutation.
/// Hydrated lazily on first `load()` (idempotent).
class AppPreferencesNotifier extends ChangeNotifier {
  AppPreferencesNotifier(this._repository);

  final AppPreferencesRepository _repository;

  AppPreferences _value = const AppPreferences();
  bool _hydrated = false;

  AppPreferences get value => _value;
  bool get hydrated => _hydrated;

  /// Seeds an already-loaded snapshot (from `main()`'s pre-`runApp` read) so the
  /// provider is hydrated from its very first build — the transport (Tor vs
  /// clearnet) is then known before the first connection, so a Tor user
  /// connects ONCE over Tor instead of connecting clearnet, loading prefs, then
  /// reconnecting. Marks [hydrated]; a later [load] becomes a no-op. Bootstrap
  /// only (called before any listener), so it doesn't notify.
  void hydrateFrom(AppPreferences prefs) {
    _value = prefs;
    _hydrated = true;
  }

  /// Hydrates from `SecureStorage`. Idempotent — second call is a no-op.
  /// ALWAYS marks hydrated (even if the read fails → defaults): the SOCKS
  /// routing layer holds the connection fail-closed until `hydrated`, so a
  /// load that never resolved would strand the app offline.
  Future<void> load() async {
    if (_hydrated) return;
    try {
      var loaded = await _repository.load();
      // App lock is one factor at a time. An older install (or a half-applied
      // toggle) may have both a passcode and biometric unlock set; keep the
      // passcode and drop biometric so the two can't both be active.
      if (loaded.passcodeEnabled && loaded.biometricUnlock) {
        loaded = loaded.copyWith(biometricUnlock: false);
        await _repository.save(loaded);
      }
      _value = loaded;
    } catch (e) {
      debugPrint('AppPreferences: load failed, using defaults: $e');
    } finally {
      _hydrated = true;
      notifyListeners();
    }
  }

  Future<void> setThemeMode(AppThemeMode mode) =>
      _update(_value.copyWith(themeMode: mode));

  /// Picks a preset backdrop (or none). A preset drops any stored photo path.
  Future<void> setChatBackground(ChatBackground background) => _update(
        _value.copyWith(chatBackground: background, chatBackgroundPath: ''),
      );

  /// Uses the photo at [path] as the chat backdrop.
  Future<void> setCustomChatBackground(String path) => _update(
        _value.copyWith(
          chatBackground: ChatBackground.custom,
          chatBackgroundPath: path,
        ),
      );

  Future<void> setTextSize(TextSize size) =>
      _update(_value.copyWith(textSize: size));

  Future<void> setNotificationsEnabled(bool enabled) =>
      _update(_value.copyWith(notificationsEnabled: enabled));

  Future<void> setDisappearingDefault(DisappearingDefault d) =>
      _update(_value.copyWith(disappearingDefault: d));

  Future<void> setBiometricUnlock(bool enabled) =>
      _update(_value.copyWith(biometricUnlock: enabled));

  Future<void> setPasscodeEnabled(bool enabled) =>
      _update(_value.copyWith(passcodeEnabled: enabled));

  Future<void> setBlockScreenshots(bool enabled) =>
      _update(_value.copyWith(blockScreenshots: enabled));

  Future<void> setBlockForwarding(bool enabled) =>
      _update(_value.copyWith(blockForwarding: enabled));

  Future<void> setSendReadReceipts(bool enabled) =>
      _update(_value.copyWith(sendReadReceipts: enabled));

  Future<void> setLinkPreviewMode(LinkPreviewMode mode) =>
      _update(_value.copyWith(linkPreviewMode: mode));

  Future<void> setServerUrl(String url) =>
      _update(_value.copyWith(serverUrl: url));

  Future<void> setUseTor(bool enabled) =>
      _update(_value.copyWith(useTor: enabled));

  Future<void> setTorOnionUrl(String url) =>
      _update(_value.copyWith(torOnionUrl: url));

  Future<void> setSocksProxyEnabled(bool enabled) =>
      _update(_value.copyWith(socksProxyEnabled: enabled));

  Future<void> setSocksProxyHost(String host) =>
      _update(_value.copyWith(socksProxyHost: host));

  Future<void> setSocksProxyPort(int port) =>
      _update(_value.copyWith(socksProxyPort: port));

  Future<void> setBuiltInTorEnabled(bool enabled) =>
      _update(_value.copyWith(builtInTorEnabled: enabled));

  Future<void> setPushOverFcmEnabled(bool enabled) =>
      _update(_value.copyWith(pushOverFcmEnabled: enabled));

  Future<void> setPushPromptSeen(bool seen) =>
      _update(_value.copyWith(pushPromptSeen: seen));

  Future<void> _update(AppPreferences next) async {
    if (next == _value) return;
    // Apply + repaint OPTIMISTICALLY, before the (encrypted, keystore-backed)
    // SecureStorage write — that write takes a perceptible beat on Android,
    // and notifying only after it made every toggle/radio in settings lag
    // visibly behind the tap. The in-memory value is the source of truth for
    // the session; persistence just survives a restart, so it can settle in
    // the background. If the write throws, the in-memory value still stands
    // (next launch simply reloads the last successfully-persisted value).
    _value = next;
    notifyListeners();
    try {
      await _repository.save(next);
    } catch (e) {
      debugPrint('AppPreferences: persist failed (kept in memory): $e');
    }
  }
}
