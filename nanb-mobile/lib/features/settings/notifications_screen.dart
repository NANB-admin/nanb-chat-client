import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/design_tokens.dart';
import '../../app/providers.dart';
import 'widgets/background_receipt_row.dart';
import 'widgets/push_status_card.dart';
import 'widgets/settings_scaffold.dart';

class NotificationsScreen extends ConsumerWidget {
  const NotificationsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.watch(appPreferencesProvider);
    final t = DesignTokens.of(context);
    return SettingsScaffold(
      title: 'Notifications',
      child: ListView(
        children: [
          const SettingsSectionHeader(label: 'Push notifications'),
          SettingsCard(
            children: [
              _SwitchRow(
                t: t,
                label: 'Enable notifications',
                sub: 'Wake the app on incoming messages.',
                value: notifier.value.notificationsEnabled,
                onChanged: notifier.setNotificationsEnabled,
                last: true,
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 16, 14, 0),
            child: Text(
              'Notifications never carry message content — Chat wakes you, then '
              'decrypts on this device when you open it.',
              style: TextStyle(fontSize: 12, color: t.textMuted, height: 1.5),
            ),
          ),
          const PushStatusCard(),
          const BackgroundReceiptRow(),
        ],
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
                Text(sub, style: TextStyle(fontSize: 12, color: t.textMuted)),
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
