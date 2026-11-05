import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/design_tokens.dart';
import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../core/network/tor/tor_controller.dart';
import '../../core/network/tor/tor_status.dart';
import 'app_preferences_notifier.dart';
import 'widgets/catchup_diagnostics_row.dart';
import 'widgets/connection_log_row.dart';
import 'widgets/settings_scaffold.dart';

class NetworkScreen extends ConsumerStatefulWidget {
  const NetworkScreen({super.key});

  @override
  ConsumerState<NetworkScreen> createState() => _NetworkScreenState();
}

class _NetworkScreenState extends ConsumerState<NetworkScreen> {
  late final TextEditingController _serverController;
  late final TextEditingController _onionController;
  late final TextEditingController _socksHostController;
  late final TextEditingController _socksPortController;
  bool _saved = false;
  bool _saving = false;

  /// The server-endpoint field is read-only until the user taps Edit; tapping
  /// Save persists + locks it again. Guards against accidental edits to the URL.
  bool _editingServer = false;

  @override
  void initState() {
    super.initState();
    final prefs = ref.read(appPreferencesProvider).value;
    _serverController = TextEditingController(text: prefs.serverUrl);
    _onionController = TextEditingController(text: prefs.torOnionUrl);
    _socksHostController = TextEditingController(text: prefs.socksProxyHost);
    _socksPortController =
        TextEditingController(text: prefs.socksProxyPort.toString());
  }

  @override
  void dispose() {
    _serverController.dispose();
    _onionController.dispose();
    _socksHostController.dispose();
    _socksPortController.dispose();
    super.dispose();
  }

  /// True when the SOCKS host field holds a literal IP. A hostname (e.g.
  /// "localhost") cannot be resolved synchronously by `buildHttpClient`, which
  /// would throw on connect and leave the app stuck reconnecting with no
  /// feedback — so we gate enabling/saving on this.
  bool get _socksHostValid =>
      InternetAddress.tryParse(_socksHostController.text.trim()) != null;

  void _warn(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  /// Enabling SOCKS reconnects immediately, so apply the host/port currently
  /// shown in the fields (not the last-saved values) and refuse to enable with
  /// a non-IP host.
  Future<void> _setSocksEnabled(bool enabled, AppPreferencesNotifier notifier) async {
    if (enabled && !_socksHostValid) {
      _warn('SOCKS host must be a literal IP (e.g. 127.0.0.1).');
      if (mounted) setState(() {}); // snap the switch back to off
      return;
    }
    await notifier.setSocksProxyHost(_socksHostController.text.trim());
    final port = int.tryParse(_socksPortController.text.trim());
    if (port != null && port > 0 && port < 65536) {
      await notifier.setSocksProxyPort(port);
    }
    await notifier.setSocksProxyEnabled(enabled);
  }

  /// Enabling/disabling built-in Tor switches the app's transport: persist the
  /// pref (the app-root listener starts/stops the Tor engine), then tear down
  /// the active session + rebuild the HTTP/WS clients so the next chat-list
  /// entry connects through (or away from) Tor — same mechanism as a server-URL
  /// change. While Tor bootstraps, socksProxyProvider holds traffic fail-closed.
  Future<void> _setBuiltInTor(bool enabled, AppPreferencesNotifier notifier) async {
    await notifier.setBuiltInTorEnabled(enabled);
    await ref.read(conversationsProvider).disconnect();
    ref.invalidate(apiClientProvider);
    ref.invalidate(wsClientProvider);
  }

  String _torStatusLine(bool enabled, TorController tor) {
    if (!enabled) return 'Off — the app connects directly.';
    switch (tor.phase) {
      case TorPhase.off:
      case TorPhase.starting:
        return 'Starting Tor…';
      case TorPhase.bootstrapping:
        final pct = tor.status.bootstrapPercent;
        final detail = tor.status.message;
        final suffix = (detail != null && detail.isNotEmpty) ? ' — $detail' : '';
        return 'Connecting to the Tor network… $pct%$suffix';
      case TorPhase.connected:
        return 'Connected. All traffic is routed over Tor.';
      case TorPhase.error:
        return 'Tor error: ${tor.status.message ?? 'failed'} — retrying.';
    }
  }

  /// Persists the edited server URL, tears down the active session so the next
  /// chat-list entry reconnects against it, and re-locks the field (Save → Edit).
  Future<void> _saveServerUrl() async {
    final notifier = ref.read(appPreferencesProvider);
    final url = _serverController.text.trim();
    if (url.isEmpty) return;
    if (kInAppTorRoutingEnabled) {
      // If routing through SOCKS, the host must be a literal IP or
      // buildHttpClient throws on connect and the app gets stuck reconnecting.
      if (notifier.value.socksProxyEnabled && !_socksHostValid) {
        _warn('SOCKS host must be a literal IP (e.g. 127.0.0.1).');
        return;
      }
    }
    setState(() {
      _saving = true;
      _saved = false;
    });
    try {
      if (kInAppTorRoutingEnabled) {
        await notifier.setTorOnionUrl(_onionController.text.trim());
        await notifier.setSocksProxyHost(_socksHostController.text.trim());
        final port = int.tryParse(_socksPortController.text.trim());
        if (port != null && port > 0 && port < 65536) {
          await notifier.setSocksProxyPort(port);
        }
      }
      await notifier.setServerUrl(url);
      // Tear down the active session so the next chat-list entry reconnects
      // against the new URL (invalidating rebuilds ApiClient + WS; the in-flight
      // WebSocket needs an explicit disconnect).
      await ref.read(conversationsProvider).disconnect();
      ref.invalidate(apiClientProvider);
      ref.invalidate(wsClientProvider);
      if (mounted) {
        setState(() {
          _saved = true;
          _editingServer = false;
        });
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final notifier = ref.watch(appPreferencesProvider);
    final tor = ref.watch(torControllerProvider);
    final t = DesignTokens.of(context);
    return SettingsScaffold(
      title: 'Network',
      child: ListView(
        children: [
          const SettingsSectionHeader(label: 'Connection health'),
          const CatchupDiagnosticsRow(),
          const ConnectionLogRow(),
          const SizedBox(height: 8),
          const SettingsSectionHeader(label: 'Server endpoint'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Container(
              decoration: BoxDecoration(
                color: t.surface,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: t.borderStrong),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: TextField(
                controller: _serverController,
                autocorrect: false,
                enableSuggestions: false,
                keyboardType: TextInputType.url,
                // Locked until the user taps Edit (see _editingServer).
                enabled: _editingServer,
                onChanged: (_) => setState(() => _saved = false),
                decoration: const InputDecoration(
                  border: InputBorder.none,
                  disabledBorder: InputBorder.none,
                  contentPadding: EdgeInsets.symmetric(vertical: 12),
                  hintText: 'https://nanb.link',
                ),
                // Keep the URL legible even when locked (don't dim to the
                // disabled colour).
                style: monoStyle(
                  fontSize: 13,
                  color: _editingServer ? t.text : t.textMuted,
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _saved
                        ? 'Saved. The next chat-list entry will reconnect against the new URL.'
                        : 'New URL applies on save — the active WebSocket is torn down and reconnects.',
                    style: monoStyle(
                      fontSize: 10,
                      color: _saved ? t.accent : t.textMuted,
                      letterSpacing: 0.3,
                    ).copyWith(height: 1.5),
                  ),
                ),
                TextButton(
                  // Edit unlocks the field; Save persists + re-locks it.
                  onPressed: _saving
                      ? null
                      : () async {
                          if (_editingServer) {
                            await _saveServerUrl();
                          } else {
                            setState(() => _editingServer = true);
                          }
                        },
                  child: _saving
                      ? SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: t.accent,
                          ),
                        )
                      : Text(_editingServer ? 'Save' : 'Edit'),
                ),
              ],
            ),
          ),
          // Built-in Tor (docs/embedded-tor-design.md): an in-app Tor engine
          // routes all traffic over Tor with no second app. Always visible —
          // this is the supported, working path (unlike the gated manual SOCKS
          // below). Toggling switches the transport immediately.
          // Gated behind kBuiltInTorEnabled: the client is verified but the
          // server isn't reachable over Tor yet, so the toggle stays hidden to
          // avoid stranding users. Flip the flag once server-side Tor works.
          if (kBuiltInTorEnabled) ...[
          const SettingsSectionHeader(label: 'Tor (built-in)'),
          SettingsCard(
            children: [
              _SwitchRow(
                t: t,
                label: 'Route over Tor (built-in)',
                sub: _torStatusLine(notifier.value.builtInTorEnabled, tor),
                value: notifier.value.builtInTorEnabled,
                onChanged: (v) => _setBuiltInTor(v, notifier),
                last: true,
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
            child: Text(
              'Hides your IP from the server by routing through the Tor network — '
              'no Orbot or other app needed. Connecting can take a few seconds; '
              'while it does, traffic is held rather than sent in the clear.',
              style: TextStyle(fontSize: 12, color: t.textMuted, height: 1.5),
            ),
          ),
          const SizedBox(height: 8),
          ],
          // Legacy: Tor via Orbot's VPN mode (transparent, OS-level). Kept as a
          // fallback; superseded by built-in Tor above.
          // Web has no Tor, so the Orbot section is hidden there.
          if (!kIsWeb) ...[
          const SettingsSectionHeader(label: 'Tor via Orbot (alternative)'),
          SettingsCard(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.shield_outlined, size: 16, color: t.accent),
                        const SizedBox(width: 8),
                        Text(
                          'Routed through Tor via Orbot',
                          style: TextStyle(fontSize: 14, color: t.text),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'To route Chat over Tor, install Orbot and turn it on '
                      'in VPN mode. Orbot transparently tunnels everything the app '
                      'sends — both its requests and the live message socket — '
                      'through the Tor network, so your real IP is never exposed '
                      'to the server. Nothing else to configure here: when Orbot '
                      'is on, you\'re on Tor; turn it off to connect directly.',
                      style: TextStyle(
                        fontSize: 12,
                        color: t.textMuted,
                        height: 1.5,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          ],
          // In-app Tor routing (SOCKS proxy + onion endpoint) is hidden behind
          // a feature flag until it's properly implemented — it doesn't work
          // with Orbot's VPN mode. See kInAppTorRoutingEnabled. Tor still works
          // via Orbot's VPN transparently routing the clearnet URL.
          if (kInAppTorRoutingEnabled) ...[
            const SettingsSectionHeader(label: 'SOCKS proxy'),
            SettingsCard(
              children: [
                _SwitchRow(
                  t: t,
                  label: 'Route through SOCKS proxy',
                  sub: 'Tunnel all traffic through a local Tor proxy (Orbot).',
                  value: notifier.value.socksProxyEnabled,
                  onChanged: (v) => _setSocksEnabled(v, notifier),
                  last: true,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: _BoxedField(
                      t: t,
                      controller: _socksHostController,
                      hintText: '127.0.0.1',
                      keyboardType: TextInputType.url,
                      onChanged: () => setState(() => _saved = false),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    flex: 1,
                    child: _BoxedField(
                      t: t,
                      controller: _socksPortController,
                      hintText: '9050',
                      keyboardType: TextInputType.number,
                      onChanged: () => setState(() => _saved = false),
                    ),
                  ),
                ],
              ),
            ),
            const SettingsSectionHeader(label: 'Tor'),
            SettingsCard(
              children: [
                _SwitchRow(
                  t: t,
                  label: 'Prefer onion endpoint',
                  sub: notifier.value.torOnionUrl.isEmpty
                      ? 'Set an onion URL below to enable.'
                      : 'When on, all requests go to the .onion URL.',
                  value: notifier.value.useTor,
                  onChanged: notifier.value.torOnionUrl.isEmpty
                      ? null
                      : notifier.setUseTor,
                  last: true,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: _BoxedField(
                t: t,
                controller: _onionController,
                hintText: 'http://abc123…onion:8080',
                keyboardType: TextInputType.url,
                onChanged: () => setState(() => _saved = false),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 16, 14, 0),
              child: Text(
                'Reaching a .onion address requires the SOCKS proxy above to be on '
                '— start Tor on the device (Orbot in proxy/VPN mode exposes '
                '127.0.0.1:9050) and the app routes its requests + live socket '
                'through it. With the proxy off, .onion only resolves if the OS '
                'itself sends .onion traffic through Tor. The server-side onion '
                'endpoint is documented in `nanb-server/deploy/tor/torrc`.',
                style: TextStyle(fontSize: 12, color: t.textMuted, height: 1.5),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Boxed single-line text field matching the server-endpoint input style.
class _BoxedField extends StatelessWidget {
  const _BoxedField({
    required this.t,
    required this.controller,
    required this.hintText,
    required this.keyboardType,
    required this.onChanged,
  });
  final DesignTokens t;
  final TextEditingController controller;
  final String hintText;
  final TextInputType keyboardType;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: t.borderStrong),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: TextField(
        controller: controller,
        autocorrect: false,
        enableSuggestions: false,
        keyboardType: keyboardType,
        onChanged: (_) => onChanged(),
        decoration: InputDecoration(
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(vertical: 12),
          hintText: hintText,
        ),
        style: monoStyle(fontSize: 13, color: t.text),
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
  final ValueChanged<bool>? onChanged;
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
                  style: monoStyle(fontSize: 10, color: t.textMuted, letterSpacing: 0.3),
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
