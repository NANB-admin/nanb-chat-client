import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/design_tokens.dart';
import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../core/platform/secure_screen.dart';
import '../app_lock/set_passcode_screen.dart';
import '../app_lock/verify_passcode_screen.dart';
import 'models/app_preferences.dart';
import 'models/disappearing_default.dart';
import 'widgets/settings_scaffold.dart';
import 'models/link_preview_mode.dart';

/// The app-lock factor. Passcode and biometric are mutually exclusive — only
/// one can be active at a time.
enum _AppLockMode { off, passcode, biometric }

class PrivacyScreen extends ConsumerWidget {
  const PrivacyScreen({super.key});

  /// Current app-lock mode derived from prefs. Passcode wins if an older
  /// install somehow has both set (the notifier normalises this on load).
  _AppLockMode _modeFor(AppPreferences v) {
    if (v.passcodeEnabled) return _AppLockMode.passcode;
    if (v.biometricUnlock) return _AppLockMode.biometric;
    return _AppLockMode.off;
  }

  /// Switches the app-lock factor. One factor at a time, so every transition
  /// normalises the other off. Enabling is gated on a live auth (so the user
  /// can't lock themselves out); turning the lock off is gated on the current
  /// factor.
  Future<void> _selectAppLock(
    BuildContext context,
    WidgetRef ref,
    _AppLockMode target,
  ) async {
    if (_modeFor(ref.read(appPreferencesProvider).value) == target) return;
    switch (target) {
      case _AppLockMode.off:
        await _disableAppLock(context, ref);
      case _AppLockMode.passcode:
        await _enablePasscode(context, ref);
      case _AppLockMode.biometric:
        await _enableBiometric(context, ref);
    }
  }

  /// Lifts the app lock. Proves the current factor first, then clears both so
  /// no stale factor lingers.
  Future<void> _disableAppLock(BuildContext context, WidgetRef ref) async {
    final prefs = ref.read(appPreferencesProvider);
    final lock = ref.read(appLockServiceProvider);
    final passcode = ref.read(passcodeServiceProvider);
    final nav = Navigator.of(context);

    if (prefs.value.passcodeEnabled) {
      final ok = await nav.push<bool>(
        MaterialPageRoute(
          builder: (_) =>
              const VerifyPasscodeScreen(title: 'Enter passcode to turn off'),
        ),
      );
      if (ok != true) return;
    } else if (prefs.value.biometricUnlock) {
      if (!await lock.authenticate(reason: 'Confirm to turn off app lock')) {
        return;
      }
    }
    await passcode.clear();
    await prefs.setPasscodeEnabled(false);
    await prefs.setBiometricUnlock(false);
  }

  /// Sets an app passcode. SetPasscodeScreen stores the hash, flips
  /// `passcodeEnabled`, and unlocks; we then drop biometric (one at a time).
  Future<void> _enablePasscode(BuildContext context, WidgetRef ref) async {
    final prefs = ref.read(appPreferencesProvider);
    final nav = Navigator.of(context);

    final set = await nav.push<bool>(
      MaterialPageRoute(builder: (_) => const SetPasscodeScreen()),
    );
    if (set != true) return;
    await prefs.setBiometricUnlock(false);
  }

  /// Turns on biometric unlock. Confirms the device can authenticate and that
  /// the user passes a live prompt (so they can't lock themselves out), then
  /// drops any passcode (one at a time).
  Future<void> _enableBiometric(BuildContext context, WidgetRef ref) async {
    final prefs = ref.read(appPreferencesProvider);
    final lock = ref.read(appLockServiceProvider);
    final passcode = ref.read(passcodeServiceProvider);
    final messenger = ScaffoldMessenger.of(context);

    if (!await lock.canAuthenticate()) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            'Set up a fingerprint, face unlock, or a screen lock (PIN/'
            'pattern/password) in your device settings first.',
          ),
        ),
      );
      return;
    }
    if (!await lock.authenticate(reason: 'Confirm to enable app lock')) return;
    await prefs.setBiometricUnlock(true);
    await passcode.clear();
    await prefs.setPasscodeEnabled(false);
    // They just authenticated — don't immediately re-lock them out.
    ref.read(appLockControllerProvider).unlock();
  }

  /// Flips a conversation-privacy flag: persists the pref, applies
  /// FLAG_SECURE locally (screenshots only), and broadcasts the new flags
  /// to every active 1:1 so peers apply them immediately.
  Future<void> _setConversationPrivacy(
    WidgetRef ref, {
    bool? screenshots,
    bool? forwarding,
  }) async {
    final prefs = ref.read(appPreferencesProvider);
    if (screenshots != null) {
      await prefs.setBlockScreenshots(screenshots);
      await SecureScreen.setGlobal(screenshots);
    }
    if (forwarding != null) {
      await prefs.setBlockForwarding(forwarding);
    }
    final v = prefs.value;
    // Fire-and-forget: each conversation send is best-effort and the
    // per-message PrivacyHeader self-heals any that miss the broadcast.
    unawaited(ref.read(conversationsProvider).broadcastPrivacyFlags(
          screenshots: v.blockScreenshots,
          forwarding: v.blockForwarding,
        ));
  }

  /// Turns Google FCM push on/off. Persists the pref, then applies it as
  /// immediately as possible: ON flips FCM auto-init back on (full background
  /// delivery resumes after the next launch, where `main()` also registers the
  /// background handler); OFF severs Google now — disables auto-init, deletes
  /// the FCM token, and deregisters it server-side. (When push was off for the
  /// whole session Firebase isn't initialized, so the auto-init call no-ops and
  /// the change fully lands on restart — covered by the on-screen note.)
  Future<void> _setPushOverFcm(WidgetRef ref, bool enabled) async {
    await ref.read(appPreferencesProvider).setPushOverFcmEnabled(enabled);
    final fcm = ref.read(firebaseMessagingFacadeProvider);
    await fcm.setAutoInitEnabled(enabled);
    if (!enabled) {
      await fcm.deleteToken();
      try {
        await ref.read(apiClientProvider).deletePushToken();
      } catch (_) {/* best-effort; server drops stale tokens on send failure */}
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.watch(appPreferencesProvider);
    final t = DesignTokens.of(context);
    final mode = _modeFor(notifier.value);
    return SettingsScaffold(
      title: 'Privacy',
      child: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          const SettingsSectionHeader(label: 'Delete messages after'),
          SettingsCard(
            children: [
              for (final d in DisappearingDefault.values)
                _RadioRow(
                  t: t,
                  label: d.label,
                  selected: notifier.value.disappearingDefault == d,
                  onTap: () => notifier.setDisappearingDefault(d),
                  last: d == DisappearingDefault.values.last,
                ),
            ],
          ),
          const SettingsSectionHeader(label: 'App lock'),
          SettingsCard(
            children: [
              _RadioRow(
                t: t,
                label: 'Off',
                selected: mode == _AppLockMode.off,
                onTap: () => _selectAppLock(context, ref, _AppLockMode.off),
                last: false,
              ),
              _RadioRow(
                t: t,
                label: 'App passcode',
                selected: mode == _AppLockMode.passcode,
                onTap: () =>
                    _selectAppLock(context, ref, _AppLockMode.passcode),
                last: false,
              ),
              _RadioRow(
                t: t,
                label: 'Biometric unlock',
                selected: mode == _AppLockMode.biometric,
                onTap: () =>
                    _selectAppLock(context, ref, _AppLockMode.biometric),
                last: true,
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
            child: Text(
              'Require a 6-digit passcode, or your biometrics / device PIN, to '
              'open the app. Only one can be active at a time.',
              style: TextStyle(fontSize: 11, color: t.textFaint, height: 1.5),
            ),
          ),
          const SettingsSectionHeader(label: 'Conversation privacy'),
          SettingsCard(
            children: [
              _SwitchRow(
                t: t,
                label: 'Block screenshots',
                sub: notifier.value.blockScreenshots
                    ? 'On — no screenshots of this app, and contacts’ '
                        'apps block screenshots of chats with you.'
                    : 'Blocks screenshots of this app and of your chats on '
                        'contacts’ devices.',
                value: notifier.value.blockScreenshots,
                onChanged: (enable) =>
                    _setConversationPrivacy(ref, screenshots: enable),
                last: false,
              ),
              _SwitchRow(
                t: t,
                label: 'Block forwarding',
                sub: notifier.value.blockForwarding
                    ? 'On — contacts can’t forward or copy your messages.'
                    : 'Stops contacts forwarding or copying your messages.',
                value: notifier.value.blockForwarding,
                onChanged: (enable) =>
                    _setConversationPrivacy(ref, forwarding: enable),
                last: true,
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
            child: Text(
              'Applies to 1:1 chats. Enforced by the Chat app on both ends '
              '— it can’t stop a modified client or a photo of the '
              'screen.',
              style: TextStyle(fontSize: 11, color: t.textFaint, height: 1.5),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 16, 14, 0),
            child: Text(
              'Applies to all your 1:1 chats. Contacts converge on your current '
              'setting the next time they connect or you message them.',
              style: TextStyle(fontSize: 12, color: t.textMuted, height: 1.5),
            ),
          ),
          const SettingsSectionHeader(label: 'Read receipts'),
          SettingsCard(
            children: [
              _SwitchRow(
                t: t,
                label: 'Send read receipts',
                sub: notifier.value.sendReadReceipts
                    ? 'On — contacts can see when you’ve read their messages.'
                    : 'Off — contacts aren’t told when you read their messages.',
                value: notifier.value.sendReadReceipts,
                onChanged: (enable) => notifier.setSendReadReceipts(enable),
                last: true,
              ),
            ],
          ),
          const SettingsSectionHeader(label: 'Link previews'),
          SettingsCard(
            children: [
              _SwitchRow(
                t: t,
                label: 'Preview links I send',
                sub: notifier.value.linkPreviewMode == LinkPreviewMode.off
                    ? 'Off — links are sent as plain text.'
                    : 'On — a title and picture are fetched for links you '
                        'send. Your contact never visits the site.',
                value: notifier.value.linkPreviewMode != LinkPreviewMode.off,
                onChanged: (enable) => notifier.setLinkPreviewMode(
                  enable ? LinkPreviewMode.viaTor : LinkPreviewMode.off,
                ),
                last: notifier.value.linkPreviewMode == LinkPreviewMode.off,
              ),
              if (notifier.value.linkPreviewMode != LinkPreviewMode.off)
                _SwitchRow(
                  t: t,
                  label: 'Also when Tor is off',
                  sub: notifier.value.linkPreviewMode == LinkPreviewMode.always
                      ? 'On — with Tor off, the linked site sees your IP '
                          'address.'
                      : 'Off — previews are made only over Tor, so the site '
                          'never sees your IP.',
                  value:
                      notifier.value.linkPreviewMode == LinkPreviewMode.always,
                  onChanged: (enable) => notifier.setLinkPreviewMode(
                    enable ? LinkPreviewMode.always : LinkPreviewMode.viaTor,
                  ),
                  last: true,
                ),
            ],
          ),
          const SettingsSectionHeader(label: 'Push notifications'),
          SettingsCard(
            children: [
              _SwitchRow(
                t: t,
                label: 'Google push (FCM)',
                sub: notifier.value.pushOverFcmEnabled
                    ? 'On — Google delivers wakeups and sees this device’s IP '
                        '(not via Tor).'
                    : 'Off — Google is never contacted; messages arrive when '
                        'you open the app.',
                value: notifier.value.pushOverFcmEnabled,
                onChanged: (enable) => _setPushOverFcm(ref, enable),
                last: true,
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
            child: Text(
              'Push is delivered by Google Firebase (FCM), which runs outside '
              'Tor — when on, Google learns this device’s IP address, push '
              'token, and message timing. Turn off for maximum privacy: the app '
              'never contacts Google, and you’ll see messages when you open it. '
              'Takes full effect after you restart the app.',
              style: TextStyle(fontSize: 11, color: t.textFaint, height: 1.5),
            ),
          ),
        ],
      ),
    );
  }
}

class _RadioRow extends StatelessWidget {
  const _RadioRow({
    required this.t,
    required this.label,
    required this.selected,
    required this.onTap,
    required this.last,
  });
  final DesignTokens t;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final bool last;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        decoration: BoxDecoration(
          border: last ? null : Border(bottom: BorderSide(color: t.border)),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(label, style: TextStyle(fontSize: 14, color: t.text)),
            ),
            if (selected)
              Icon(Icons.check, size: 18, color: t.accent)
            else
              Container(
                width: 16,
                height: 16,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: t.border, width: 1.5),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.t,
    required this.label,
    required this.sub,
    required this.value,
    required this.onChanged,
    required this.last,
  });

  final DesignTokens t;
  final String label;
  final String sub;
  final bool value;
  final ValueChanged<bool> onChanged;
  final bool last;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        border: last ? null : Border(bottom: BorderSide(color: t.border)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(label, style: TextStyle(fontSize: 14, color: t.text)),
                const SizedBox(height: 2),
                Text(
                  sub,
                  style: monoStyle(
                    fontSize: 10,
                    color: t.textMuted,
                    letterSpacing: 0.3,
                  ),
                ),
              ],
            ),
          ),
          Switch(
            value: value,
            onChanged: onChanged,
            activeThumbColor: t.accent,
          ),
        ],
      ),
    );
  }
}
