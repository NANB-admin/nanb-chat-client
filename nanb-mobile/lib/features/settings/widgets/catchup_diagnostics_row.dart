import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/design_tokens.dart';
import '../../../app/providers.dart';

/// Shows where the last catchup drain spent its time, and what it failed on.
///
/// The notifier has computed `catchupDiagnostic` and `slowConnectPhases` for a
/// while, but nothing ever RENDERED them — so on a TestFlight/App Store build,
/// where every `print` and `debugPrint` is silenced for privacy, a slow or
/// partially-failing catchup was completely invisible. "Catchup must be under a
/// second" is not a target anyone can hold without a number they can read on
/// the device that is actually slow.
///
/// The split matters more than the total: the server serves a full page in
/// single-digit milliseconds, so a slow drain is always local — and `net` vs
/// `local` says whether to look at the transport (Tor circuit, cold DNS) or at
/// the per-envelope decrypt/persist path, which have nothing in common.
class CatchupDiagnosticsRow extends ConsumerWidget {
  const CatchupDiagnosticsRow({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = DesignTokens.of(context);
    final convos = ref.watch(conversationsProvider);
    final timing = convos.catchupTiming;
    final failure = convos.catchupDiagnostic;
    final slowPhases = convos.slowConnectPhases;

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 16, 14, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Last catchup',
              style: TextStyle(fontSize: 12, color: t.textMuted)),
          const SizedBox(height: 4),
          Text(
            timing.summary,
            style: TextStyle(fontSize: 12, color: t.text, height: 1.5),
          ),
          if (failure.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              failure,
              style: TextStyle(fontSize: 12, color: t.textMuted, height: 1.5),
            ),
          ],
          if (slowPhases.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              'Slow while connecting: $slowPhases',
              style: TextStyle(fontSize: 12, color: t.textMuted, height: 1.5),
            ),
          ],
        ],
      ),
    );
  }
}
