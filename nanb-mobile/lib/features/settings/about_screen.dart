import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/design_tokens.dart';
import '../../app/theme.dart';
import 'open_source_notices.dart';
import 'widgets/settings_scaffold.dart';

/// "About" screen — version (read from the installed build), license, links.
class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  // Hosted legal pages (Google Sites, custom domain). Linked here so the
  // privacy policy is reachable in-app; the same URLs go in the store listings.
  static const _privacyUrl = 'https://www.nanb.us/privacy/nanb-chat-privacy';
  static const _deletionUrl =
      'https://www.nanb.us/terms-of-service/nanb-chat-deletion-policy';

  // Public source for the app (GPL-3.0 requires it to be available to users).
  static const _sourceUrl = 'https://github.com/NANB-admin/nanb-chat-client';

  @override
  Widget build(BuildContext context) {
    final t = DesignTokens.of(context);
    return SettingsScaffold(
      title: 'About',
      child: ListView(
        padding: const EdgeInsets.symmetric(vertical: 24),
        children: [
          Center(
            child: Text(
              'Chat',
              style: monoStyle(
                fontSize: 28,
                color: t.text,
                letterSpacing: 2,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Center(
            child: Text(
              'Messages that only you can read.',
              style: TextStyle(fontSize: 14, color: t.textMuted),
            ),
          ),
          const SizedBox(height: 24),
          const SettingsSectionHeader(label: 'Build'),
          SettingsCard(
            children: [
              FutureBuilder<PackageInfo>(
                future: PackageInfo.fromPlatform(),
                builder: (context, snap) {
                  final info = snap.data;
                  return _Row(
                    t: t,
                    label: 'App version',
                    value: info == null ? '' : 'v${info.version} (${info.buildNumber})',
                  );
                },
              ),
              _Row(t: t, label: 'Domain', value: 'nanb.link', last: true),
            ],
          ),
          const SettingsSectionHeader(label: 'Cryptography'),
          SettingsCard(
            children: [
              _Row(t: t, label: 'Identity', value: 'Ed25519'),
              _Row(t: t, label: 'Group messages', value: 'MLS · RFC 9420'),
              _Row(t: t, label: 'Storage', value: 'SQLCipher', last: true),
            ],
          ),
          const SettingsSectionHeader(label: 'Open source'),
          SettingsCard(
            children: [
              _Row(t: t, label: 'License', value: 'GPL-3.0'),
              _LinkRow(t: t, label: 'Source code', url: _sourceUrl),
              _TapRow(
                t: t,
                label: 'Open-source licenses',
                last: true,
                onTap: () {
                  registerOpenSourceNotices();
                  showLicensePage(
                    context: context,
                    applicationName: 'NANb Chat',
                  );
                },
              ),
            ],
          ),
          const SettingsSectionHeader(label: 'Legal'),
          SettingsCard(
            children: [
              _LinkRow(t: t, label: 'Privacy Policy', url: _privacyUrl),
              _LinkRow(
                t: t,
                label: 'Data & deletion policy',
                url: _deletionUrl,
                last: true,
              ),
            ],
          ),
          const SizedBox(height: 24),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Text(
              'No telemetry, no analytics, no third-party crash reporting.',
              style: TextStyle(fontSize: 12, color: t.textMuted, height: 1.5),
            ),
          ),
        ],
      ),
    );
  }
}

/// Tappable row that opens [url] in the external browser. Styled to match
/// [_Row] but with an open-in-new affordance instead of a value.
class _LinkRow extends StatelessWidget {
  const _LinkRow({required this.t, required this.label, required this.url, this.last = false});
  final DesignTokens t;
  final String label;
  final String url;
  final bool last;

  Future<void> _open(BuildContext context) async {
    // Capture the messenger before the await so we don't touch `context`
    // across the async gap.
    final messenger = ScaffoldMessenger.of(context);
    try {
      final launched = await launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalApplication,
      );
      if (!launched) {
        messenger.showSnackBar(const SnackBar(content: Text('Could not open the link.')));
      }
    } catch (_) {
      messenger.showSnackBar(const SnackBar(content: Text('Could not open the link.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => _open(context),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        decoration: BoxDecoration(
          border: last ? null : Border(bottom: BorderSide(color: t.border)),
        ),
        child: Row(
          children: [
            Expanded(child: Text(label, style: TextStyle(fontSize: 14, color: t.text))),
            Icon(Icons.open_in_new, size: 16, color: t.textMuted),
          ],
        ),
      ),
    );
  }
}

/// Tappable row that runs [onTap]. Same look as [_LinkRow], for in-app targets.
class _TapRow extends StatelessWidget {
  const _TapRow({required this.t, required this.label, required this.onTap, this.last = false});
  final DesignTokens t;
  final String label;
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
            Expanded(child: Text(label, style: TextStyle(fontSize: 14, color: t.text))),
            Icon(Icons.chevron_right, size: 18, color: t.textMuted),
          ],
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.t, required this.label, required this.value, this.last = false});
  final DesignTokens t;
  final String label;
  final String value;
  final bool last;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
      decoration: BoxDecoration(
        border: last ? null : Border(bottom: BorderSide(color: t.border)),
      ),
      child: Row(
        children: [
          Expanded(child: Text(label, style: TextStyle(fontSize: 14, color: t.text))),
          Text(
            value,
            style: monoStyle(fontSize: 11, color: t.textMuted, letterSpacing: 0.3),
          ),
        ],
      ),
    );
  }
}
