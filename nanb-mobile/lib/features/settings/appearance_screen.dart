import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../app/design_tokens.dart';
import '../../app/providers.dart';
import 'app_preferences_notifier.dart';
import 'models/app_theme_mode.dart';
import 'services/chat_background_store.dart';
import 'widgets/chat_background_picker.dart';
import 'models/text_size.dart';
import 'widgets/settings_scaffold.dart';

class AppearanceScreen extends ConsumerWidget {
  const AppearanceScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.watch(appPreferencesProvider);
    return SettingsScaffold(
      title: 'Appearance',
      child: ListView(
        children: [
          const SettingsSectionHeader(label: 'Theme'),
          SettingsCard(
            children: [
              for (final mode in AppThemeMode.values)
                _ModeRow(
                  mode: mode,
                  selected: notifier.value.themeMode == mode,
                  onTap: () => notifier.setThemeMode(mode),
                  last: mode == AppThemeMode.values.last,
                ),
            ],
          ),
          const SettingsSectionHeader(label: 'Chat background'),
          SettingsCard(
            children: [
              ChatBackgroundPicker(
                selected: notifier.value.chatBackground,
                customPath: notifier.value.chatBackgroundPath,
                onSelect: (b) async {
                  await notifier.setChatBackground(b);
                  await const ChatBackgroundStore().clear();
                },
                onPickPhoto: () => _pickPhoto(context, notifier),
              ),
            ],
          ),
          const SettingsSectionHeader(label: 'Text size'),
          SettingsCard(
            children: [
              for (final size in TextSize.values)
                _TextSizeRow(
                  size: size,
                  selected: notifier.value.textSize == size,
                  onTap: () => notifier.setTextSize(size),
                  last: size == TextSize.values.last,
                ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 16, 14, 0),
            child: Text(
              'Text size scales everything in the app. Brand accent — Fern green — applies to both light and dark themes. Other accent palettes (Sky, Rust, Iris) are deferred to a future release.',
              style: TextStyle(
                fontSize: 12,
                color: DesignTokens.of(context).textMuted,
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

Future<void> _pickPhoto(
  BuildContext context,
  AppPreferencesNotifier notifier,
) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    final picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      maxWidth: 2048,
      maxHeight: 2048,
      imageQuality: 85,
    );
    if (picked == null) return;
    final saved = await const ChatBackgroundStore().save(picked.path);
    await notifier.setCustomChatBackground(saved);
  } catch (_) {
    messenger.showSnackBar(
      const SnackBar(content: Text('Couldn’t set that photo.')),
    );
  }
}

class _TextSizeRow extends StatelessWidget {
  const _TextSizeRow({
    required this.size,
    required this.selected,
    required this.onTap,
    required this.last,
  });

  final TextSize size;
  final bool selected;
  final VoidCallback onTap;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final t = DesignTokens.of(context);
    // Preview the relative size with a glyph that ignores the app-wide
    // textScaler (it IS the scaler being chosen), so each row reads at its
    // own size regardless of the current selection.
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        decoration: BoxDecoration(
          border: last ? null : Border(bottom: BorderSide(color: t.border)),
        ),
        child: Row(
          children: [
            SizedBox(
              width: 28,
              child: Text(
                'A',
                textScaler: TextScaler.noScaling,
                style: TextStyle(fontSize: 13 * size.scale, color: t.text),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(size.label,
                  style: TextStyle(fontSize: 14, color: t.text)),
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

class _ModeRow extends StatelessWidget {
  const _ModeRow({
    required this.mode,
    required this.selected,
    required this.onTap,
    required this.last,
  });

  final AppThemeMode mode;
  final bool selected;
  final VoidCallback onTap;
  final bool last;

  String get _label {
    switch (mode) {
      case AppThemeMode.system:
        return 'System';
      case AppThemeMode.light:
        return 'Light';
      case AppThemeMode.dark:
        return 'Dark';
    }
  }

  IconData get _icon {
    switch (mode) {
      case AppThemeMode.system:
        return Icons.brightness_auto_outlined;
      case AppThemeMode.light:
        return Icons.light_mode_outlined;
      case AppThemeMode.dark:
        return Icons.dark_mode_outlined;
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = DesignTokens.of(context);
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        decoration: BoxDecoration(
          border: last ? null : Border(bottom: BorderSide(color: t.border)),
        ),
        child: Row(
          children: [
            Icon(_icon, size: 18, color: t.text),
            const SizedBox(width: 12),
            Expanded(
              child: Text(_label, style: TextStyle(fontSize: 14, color: t.text)),
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
