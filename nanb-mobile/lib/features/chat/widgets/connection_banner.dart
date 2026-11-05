import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../core/network/connection_state.dart' as conn;

/// Thin chip rendered when the WS connection is anything other than
/// `connected`. Subscribes to the conversations notifier so it rebuilds
/// on every supervisor transition.
class ConnectionBanner extends ConsumerWidget {
  const ConnectionBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(conversationsProvider.select((n) => n.connectionState));
    // Tor is the chosen transport → the connecting/reconnecting label says so,
    // so the user knows the wait is the Tor path (not a generic clearnet hang).
    final viaTor = kBuiltInTorEnabled &&
        ref.watch(appPreferencesProvider.select((n) => n.value.builtInTorEnabled));

    // Deliberately NOT rendered to users: `catchupProblem` carries a raw
    // exception string ("MlsUnknownGroupException: …"), which was the right
    // trade while diagnosing an undebuggable store build but is meaningless
    // and alarming in a shipped app. The notifier still computes it, so
    // re-enabling this line is the whole of the change if a future
    // investigation needs it back.
    if (state == conn.ConnectionState.connected) {
      return const SizedBox.shrink();
    }

    final String? label = switch (state) {
      conn.ConnectionState.connected => null,
      conn.ConnectionState.connecting =>
        viaTor ? 'Connecting via Tor…' : 'Connecting…',
      conn.ConnectionState.reconnecting =>
        viaTor ? 'Reconnecting via Tor…' : 'Reconnecting…',
      conn.ConnectionState.signedOut => null, // router handles redirect
    };
    if (label == null) return const SizedBox.shrink();
    // Users see only "Connecting…". The stalled-phase name ("· waiting on
    // database") is diagnostic detail that meant nothing to them; the watchdog
    // still runs and still names the phase in `slowConnectPhases` for a future
    // investigation to read.

    return _bar(context, label, spinner: true);
  }

  /// The chip itself. `spinner: false` for a settled state (the catchup
  /// diagnostic), where a spinner would wrongly imply work in progress.
  Widget _bar(BuildContext context, String text, {required bool spinner}) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final fg = colorScheme.onSurfaceVariant;
    return Container(
      width: double.infinity,
      color: colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (spinner) ...[
            SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(
                strokeWidth: 1.5,
                valueColor: AlwaysStoppedAnimation<Color>(fg),
              ),
            ),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Text(
              text,
              textAlign: TextAlign.center,
              style: theme.textTheme.labelSmall?.copyWith(color: fg),
            ),
          ),
        ],
      ),
    );
  }
}
