import 'package:flutter/foundation.dart';

import 'app_theme_mode.dart';
import 'disappearing_default.dart';
import 'text_size.dart';
import 'link_preview_mode.dart';
import 'chat_background.dart';

/// Aggregate of every user-tunable preference. Persisted via
/// `AppPreferencesRepository`; mutated through `AppPreferencesNotifier`.
@immutable
class AppPreferences {
  const AppPreferences({
    this.themeMode = AppThemeMode.system,
    this.textSize = TextSize.medium,
    this.notificationsEnabled = true,
    this.disappearingDefault = DisappearingDefault.oneWeek,
    this.biometricUnlock = false,
    this.passcodeEnabled = false,
    this.blockScreenshots = false,
    this.blockForwarding = false,
    this.sendReadReceipts = true,
    this.serverUrl = 'https://nanb.link',
    this.useTor = false,
    this.torOnionUrl = '',
    this.socksProxyEnabled = false,
    this.socksProxyHost = '127.0.0.1',
    this.socksProxyPort = 9050,
    this.builtInTorEnabled = false,
    this.pushOverFcmEnabled = false,
    this.pushPromptSeen = false,
    this.linkPreviewMode = LinkPreviewMode.viaTor,
    this.chatBackground = ChatBackground.nanb,
    this.chatBackgroundPath = '',
  });

  final AppThemeMode themeMode;

  /// App-wide text scale (small/medium/large). Applied via a
  /// `MediaQuery.textScaler` override at the app root.
  final TextSize textSize;

  final bool notificationsEnabled;
  final DisappearingDefault disappearingDefault;

  /// When true, the app prompts the device biometric / credential on open.
  final bool biometricUnlock;

  /// When true, the app prompts for an in-app numeric passcode on open
  /// (independent of [biometricUnlock]). The PIN hash lives in SecureStorage
  /// via `PasscodeService`; this flag only records that the gate is armed.
  final bool passcodeEnabled;

  /// When true: FLAG_SECURE app-wide on this device (no screenshots of the
  /// app at all) AND peers' clients are asked — via the `PrivacyHeader` /
  /// `MessageControl.privacy` wire flags — to block screenshots while a
  /// conversation with this user is open. Client-honored, not cryptographic.
  final bool blockScreenshots;

  /// When true: peers' clients are asked to hide the Forward and Copy
  /// actions on this user's messages. Client-honored, not cryptographic.
  final bool blockForwarding;

  /// When true (default), a "read" receipt is sent to the sender when you open
  /// a 1:1 conversation. Turn off to stop telling contacts you've read their
  /// messages. Delivered receipts are unaffected.
  final bool sendReadReceipts;

  /// `nanb-server` base URL the app talks to. Defaults to production —
  /// point at `http://10.0.2.2:8080` (emulator host loopback) for local dev.
  final String serverUrl;

  /// When true AND `torOnionUrl` is non-empty, `apiBaseUrlProvider` returns
  /// the onion URL instead of `serverUrl`. The Dart client does not bundle a
  /// SOCKS proxy; this only resolves correctly if the host OS is already
  /// routing `.onion` traffic through Tor (e.g., Orbot on Android in
  /// transparent-proxy mode).
  final bool useTor;

  /// Tor v3 onion endpoint (e.g., `http://abcd.onion:8080`). The server-side
  /// onion service is documented in `nanb-server/deploy/tor/torrc`. Empty
  /// means no onion endpoint configured — toggle has no effect.
  final String torOnionUrl;

  /// When true, the app routes HTTP + the WebSocket through the SOCKS5 proxy
  /// at [socksProxyHost]:[socksProxyPort] (a local Tor client such as Orbot).
  /// This is what makes `.onion` reachable without an OS transparent proxy.
  /// See `core/network/socks_proxy.dart`.
  final bool socksProxyEnabled;

  /// SOCKS5 proxy host. Must be a literal IP — Tor's local proxy is loopback,
  /// so this defaults to `127.0.0.1`.
  final String socksProxyHost;

  /// SOCKS5 proxy port. Orbot / system Tor default is 9050 (Tor Browser 9150).
  final int socksProxyPort;

  /// When true, the app runs an **embedded** Tor engine (pure-Rust Arti, via the
  /// nanb_crypto plugin) and routes all HTTP + the WebSocket through its local
  /// SOCKS port — no Orbot, no OS proxy. Fail-closed: while the engine is
  /// bootstrapping, traffic is held (never falls back to clearnet).
  /// **Defaults to false** — a fresh install talks to the server over clearnet
  /// (fast connects, no ~16s bootstrap, no battery cost) and the user opts in
  /// to Tor in Network settings, accepting the latency for IP anonymity.
  /// Anything that reads the raw pref key outside this model (background
  /// isolate, iOS NSE, cold-start warm-up) must therefore treat an ABSENT
  /// value as OFF — only an explicit `'true'` means Tor.
  /// See `docs/embedded-tor-design.md` and `socksProxyProvider`.
  final bool builtInTorEnabled;

  /// When true, the app uses Google Firebase Cloud Messaging for offline wakeup
  /// pushes. FCM runs over Google Play Services, **NOT** Tor, so it exposes this
  /// device's IP + FCM token + wakeup timing to Google. **Defaults to false**
  /// (privacy by default): a fresh install initializes no FCM (see `main()`),
  /// registers no token, and contacts Google not at all. The user opts in via
  /// the first-launch prompt or Settings → Privacy, at which point push wakeups
  /// start (otherwise messages arrive when the app is open / connected). A
  /// runtime opt-in activates Firebase via `fcmRuntimeActivator`; a boot with
  /// the pref already on initializes it directly.
  final bool pushOverFcmEnabled;

  /// Whether the one-time "turn on notifications?" opt-in prompt has been shown.
  /// Starts false; set true after the user answers it (either way) so the prompt
  /// never re-appears. See `maybeShowPushOptIn`.
  final bool pushPromptSeen;

  /// Whether (and over which route) a link in a message you send is fetched to
  /// build a preview card. See [LinkPreviewMode].
  final LinkPreviewMode linkPreviewMode;

  /// Backdrop behind the messages in every chat thread.
  final ChatBackground chatBackground;

  /// Local file of the picked photo, used when [chatBackground] is
  /// [ChatBackground.custom]. Empty otherwise.
  final String chatBackgroundPath;

  AppPreferences copyWith({
    AppThemeMode? themeMode,
    TextSize? textSize,
    bool? notificationsEnabled,
    DisappearingDefault? disappearingDefault,
    bool? biometricUnlock,
    bool? passcodeEnabled,
    bool? blockScreenshots,
    bool? blockForwarding,
    bool? sendReadReceipts,
    String? serverUrl,
    bool? useTor,
    String? torOnionUrl,
    bool? socksProxyEnabled,
    String? socksProxyHost,
    int? socksProxyPort,
    bool? builtInTorEnabled,
    bool? pushOverFcmEnabled,
    bool? pushPromptSeen,
    LinkPreviewMode? linkPreviewMode,
    ChatBackground? chatBackground,
    String? chatBackgroundPath,
  }) {
    return AppPreferences(
      themeMode: themeMode ?? this.themeMode,
      textSize: textSize ?? this.textSize,
      notificationsEnabled: notificationsEnabled ?? this.notificationsEnabled,
      disappearingDefault: disappearingDefault ?? this.disappearingDefault,
      biometricUnlock: biometricUnlock ?? this.biometricUnlock,
      passcodeEnabled: passcodeEnabled ?? this.passcodeEnabled,
      blockScreenshots: blockScreenshots ?? this.blockScreenshots,
      blockForwarding: blockForwarding ?? this.blockForwarding,
      sendReadReceipts: sendReadReceipts ?? this.sendReadReceipts,
      serverUrl: serverUrl ?? this.serverUrl,
      useTor: useTor ?? this.useTor,
      torOnionUrl: torOnionUrl ?? this.torOnionUrl,
      socksProxyEnabled: socksProxyEnabled ?? this.socksProxyEnabled,
      socksProxyHost: socksProxyHost ?? this.socksProxyHost,
      socksProxyPort: socksProxyPort ?? this.socksProxyPort,
      builtInTorEnabled: builtInTorEnabled ?? this.builtInTorEnabled,
      pushOverFcmEnabled: pushOverFcmEnabled ?? this.pushOverFcmEnabled,
      pushPromptSeen: pushPromptSeen ?? this.pushPromptSeen,
      linkPreviewMode: linkPreviewMode ?? this.linkPreviewMode,
      chatBackground: chatBackground ?? this.chatBackground,
      chatBackgroundPath: chatBackgroundPath ?? this.chatBackgroundPath,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AppPreferences &&
          themeMode == other.themeMode &&
          textSize == other.textSize &&
          notificationsEnabled == other.notificationsEnabled &&
          disappearingDefault == other.disappearingDefault &&
          biometricUnlock == other.biometricUnlock &&
          passcodeEnabled == other.passcodeEnabled &&
          blockScreenshots == other.blockScreenshots &&
          blockForwarding == other.blockForwarding &&
          sendReadReceipts == other.sendReadReceipts &&
          serverUrl == other.serverUrl &&
          useTor == other.useTor &&
          torOnionUrl == other.torOnionUrl &&
          socksProxyEnabled == other.socksProxyEnabled &&
          socksProxyHost == other.socksProxyHost &&
          socksProxyPort == other.socksProxyPort &&
          builtInTorEnabled == other.builtInTorEnabled &&
          pushOverFcmEnabled == other.pushOverFcmEnabled &&
          pushPromptSeen == other.pushPromptSeen &&
          linkPreviewMode == other.linkPreviewMode &&
          chatBackground == other.chatBackground &&
          chatBackgroundPath == other.chatBackgroundPath;

  @override
  int get hashCode => Object.hashAll([
        themeMode,
        textSize,
        notificationsEnabled,
        disappearingDefault,
        biometricUnlock,
        passcodeEnabled,
        blockScreenshots,
        blockForwarding,
        sendReadReceipts,
        serverUrl,
        useTor,
        torOnionUrl,
        socksProxyEnabled,
        socksProxyHost,
        socksProxyPort,
        builtInTorEnabled,
        pushOverFcmEnabled,
        pushPromptSeen,
        linkPreviewMode,
        chatBackground,
        chatBackgroundPath,
      ]);
}
