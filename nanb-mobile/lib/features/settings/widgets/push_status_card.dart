import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/design_tokens.dart';
import '../../../app/providers.dart';
import '../../../core/push/push_permission.dart';
import '../models/push_blocker.dart';
import '../models/push_delivery_status.dart';

/// Says whether notifications can actually reach this device, names the ONE
/// thing blocking them, and fixes it in a tap.
///
/// Four independent gates have to line up — the in-app notifications toggle,
/// the in-app push-over-Google toggle (off by DEFAULT for privacy), the OS
/// permission, and a token actually registered with the server. Before this,
/// none of them were visible together and only the install-time prompt could
/// turn them on, so a user who tapped "Not now" once was stuck with silent
/// notifications forever while every screen they could see read "enabled".
class PushStatusCard extends ConsumerStatefulWidget {
  const PushStatusCard({super.key});

  @override
  ConsumerState<PushStatusCard> createState() => _PushStatusCardState();
}

class _PushStatusCardState extends ConsumerState<PushStatusCard> {
  PushPermission? _permission;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final p = await ref.read(pushEnableServiceProvider).permission();
    if (!mounted) return;
    setState(() => _permission = p);
  }

  Future<void> _enable() async {
    setState(() => _busy = true);
    final p = await ref.read(pushEnableServiceProvider).enable();
    if (!mounted) return;
    setState(() {
      _permission = p;
      _busy = false;
    });
    // Refused at the OS level: on iOS the system prompt never appears twice, so
    // saying "try again" would be a lie — send them to system settings.
    if (p == PushPermission.denied && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text(
            'Notifications are blocked for Chat in system settings.',
          ),
          action: SnackBarAction(
            label: 'OPEN',
            onPressed: () =>
                ref.read(pushEnableServiceProvider).openSystemSettings(),
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = DesignTokens.of(context);
    final prefs = ref.watch(appPreferencesProvider).value;
    final registrar = ref.watch(pushTokenRegistrarProvider);
    final status = PushDeliveryStatus(
      appNotificationsEnabled: prefs.notificationsEnabled,
      pushOverFcmEnabled: prefs.pushOverFcmEnabled,
      permission: _permission ?? PushPermission.unknown,
      hasServerToken: registrar.lastFoundNoToken
          ? false
          : registrar.lastRegistrationSucceeded,
    );
    final blocker = status.blocker;

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 16, 14, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Delivery status',
              style: TextStyle(fontSize: 12, color: t.textMuted)),
          const SizedBox(height: 6),
          Row(
            children: [
              Icon(
                status.deliverable
                    ? Icons.notifications_active_outlined
                    : Icons.notifications_off_outlined,
                size: 16,
                color: status.deliverable ? t.accent : t.textMuted,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  status.deliverable
                      ? 'Chat can wake this device.'
                      : 'Chat cannot wake this device.',
                  style: TextStyle(fontSize: 13, color: t.text),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            _explain(blocker),
            style: TextStyle(fontSize: 12, color: t.textMuted, height: 1.5),
          ),
          if (!status.deliverable) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                if (blocker == PushBlocker.osPermissionDenied)
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => ref
                            .read(pushEnableServiceProvider)
                            .openSystemSettings(),
                    child: const Text('OPEN SYSTEM SETTINGS'),
                  )
                else
                  TextButton(
                    onPressed: _busy ? null : _enable,
                    child: Text(_busy ? 'TURNING ON…' : 'TURN ON'),
                  ),
                TextButton(
                  onPressed: _busy ? null : _refresh,
                  child: const Text('RECHECK'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  /// One sentence naming the blocking gate and what it costs. Deliberately says
  /// which SCREEN owns the setting — "notifications are off" sends people to the
  /// OS, which is the wrong place for the first two.
  String _explain(PushBlocker blocker) {
    switch (blocker) {
      case PushBlocker.none:
        return 'Notifications are on and this device is registered with the '
            'server.';
      case PushBlocker.appNotificationsOff:
        return 'The "Enable notifications" switch above is off, so Chat never '
            'asks to wake this device.';
      case PushBlocker.pushOverFcmOff:
        return 'Push over Google (Settings → Privacy) is off. It is off by '
            'default for privacy, and nothing can wake a closed app without '
            'it — messages only arrive once you open Chat.';
      case PushBlocker.osPermissionNotAsked:
        return 'This device has not been asked for notification permission '
            'yet.';
      case PushBlocker.osPermissionDenied:
        return 'Notifications are blocked for Chat in system settings. That '
            'can only be changed there — Chat cannot ask again.';
      case PushBlocker.noTokenRegistered:
        return 'Everything is switched on, but no notification token reached '
            'the server, so it cannot address this device. Tap TURN ON to '
            'retry registration.';
    }
  }
}
