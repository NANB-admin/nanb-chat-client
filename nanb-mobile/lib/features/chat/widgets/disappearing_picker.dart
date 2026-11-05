import 'package:flutter/material.dart';

import '../../../app/design_tokens.dart';
import '../../settings/models/disappearing_default.dart';

/// Human label for a per-conversation disappearing override [ttlSeconds].
/// `-1` (or any non-positive value) is "Default" — the conversation follows the
/// global "Delete messages after" preference. Known preset durations render via
/// their [DisappearingDefault.label]; anything else falls back to a coarse unit.
String disappearingLabel(int ttlSeconds) {
  if (ttlSeconds <= 0) return 'Default';
  for (final d in DisappearingDefault.values) {
    if (d.ttl.inSeconds == ttlSeconds) return d.label;
  }
  final hours = ttlSeconds ~/ 3600;
  return hours >= 24 ? '${hours ~/ 24}d' : '${hours}h';
}

/// Short label for the group-info action chip (e.g. "Default", "24h").
String disappearingShortLabel(int ttlSeconds) {
  if (ttlSeconds <= 0) return 'Default';
  for (final d in DisappearingDefault.values) {
    switch (d) {
      case DisappearingDefault.oneDay:
        if (d.ttl.inSeconds == ttlSeconds) return '24h';
      case DisappearingDefault.oneWeek:
        if (d.ttl.inSeconds == ttlSeconds) return '1w';
      case DisappearingDefault.thirtyDays:
        if (d.ttl.inSeconds == ttlSeconds) return '30d';
    }
  }
  final hours = ttlSeconds ~/ 3600;
  return hours >= 24 ? '${hours ~/ 24}d' : '${hours}h';
}

/// Bottom sheet to choose a per-conversation disappearing-messages override.
/// Returns the chosen value in SECONDS (`-1` = follow the global default), or
/// `null` if dismissed. There is deliberately no "off": messages always expire,
/// matching the global default — the user only picks how fast.
Future<int?> showDisappearingPicker(
  BuildContext context, {
  required int current,
}) {
  final options = <(String, int)>[
    ('Default', -1),
    for (final d in DisappearingDefault.values) (d.label, d.ttl.inSeconds),
  ];
  return showModalBottomSheet<int>(
    context: context,
    backgroundColor: Colors.transparent,
    builder: (ctx) {
      final t = DesignTokens.of(ctx);
      return SafeArea(
        child: Container(
          decoration: BoxDecoration(
            color: t.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
            border: Border(top: BorderSide(color: t.border)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                child: Text(
                  'Disappearing messages',
                  style: TextStyle(
                    fontSize: 15,
                    color: t.text,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(
                  'New messages you send in this chat disappear after the '
                  'selected time. "Default" follows your global setting.',
                  style: TextStyle(fontSize: 12, color: t.textMuted, height: 1.4),
                ),
              ),
              const Divider(height: 1),
              Material(
                type: MaterialType.transparency,
                child: Column(
                  children: [
                    for (final (label, secs) in options)
                      ListTile(
                        key: ValueKey('disappearing-opt-$secs'),
                        title: Text(
                          label,
                          style: TextStyle(fontSize: 14, color: t.text),
                        ),
                        trailing: (secs == current ||
                                (secs == -1 && current <= 0))
                            ? Icon(Icons.check, size: 18, color: t.accent)
                            : null,
                        onTap: () => Navigator.of(ctx).pop(secs),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      );
    },
  );
}
