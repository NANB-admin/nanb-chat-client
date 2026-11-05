import 'package:flutter/material.dart';

import '../../../app/design_tokens.dart';
import '../../../app/theme.dart';

/// Shared scaffold for settings sub-screens. Top bar with mono uppercase
/// title + back button, matching the design's `SettingsHubScreen` chrome.
class SettingsScaffold extends StatelessWidget {
  const SettingsScaffold({
    super.key,
    required this.title,
    required this.child,
  });

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final t = DesignTokens.of(context);
    return Scaffold(
      backgroundColor: t.bg,
      body: SafeArea(
        child: Column(
          children: [
            _TopBar(t: t, title: title),
            Expanded(child: child),
          ],
        ),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({required this.t, required this.title});
  final DesignTokens t;
  final String title;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
      decoration: BoxDecoration(
        color: t.surface,
        border: Border(bottom: BorderSide(color: t.border)),
      ),
      child: Row(
        children: [
          IconButton(
            icon: Icon(Icons.arrow_back, color: t.text),
            iconSize: 22,
            padding: const EdgeInsets.all(4),
            constraints: const BoxConstraints(),
            onPressed: () => Navigator.of(context).maybePop(),
          ),
          const SizedBox(width: 8),
          Text(
            title.toUpperCase(),
            style: monoStyle(
              fontSize: 11,
              color: t.textMuted,
              letterSpacing: 2,
            ),
          ),
        ],
      ),
    );
  }
}

/// Section header with mono uppercase label.
class SettingsSectionHeader extends StatelessWidget {
  const SettingsSectionHeader({super.key, required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    final t = DesignTokens.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 20, 14, 8),
      child: Text(
        label.toUpperCase(),
        style: monoStyle(
          fontSize: 10,
          color: t.textFaint,
          letterSpacing: 1,
        ),
      ),
    );
  }
}

/// Card container with rounded border + surface background. Wraps a list of
/// rows; the rows themselves draw inter-row separators.
class SettingsCard extends StatelessWidget {
  const SettingsCard({super.key, required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final t = DesignTokens.of(context);
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: t.border),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Column(children: children),
      ),
    );
  }
}
