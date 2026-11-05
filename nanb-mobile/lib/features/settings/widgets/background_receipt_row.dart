import 'package:flutter/material.dart';

import '../../../app/design_tokens.dart';
import '../../../core/models/nse_receipt_outcome.dart';
import '../../../core/push/ios_shared_store.dart';

/// Reports whether the iOS Notification Service Extension managed to send a
/// closed-app "delivered" receipt for the last push it handled.
///
/// The extension is a separate process with no console on a store build, and it
/// is best-effort by design — every failure is silent, and the foreground
/// catchup quietly covers for it. That made "the sender never sees delivered
/// while I'm offline" impossible to diagnose without a special debug build. This
/// row surfaces the stage tag it reached, so one message answers it.
///
/// Renders nothing off iOS, or before the extension has ever run.
class BackgroundReceiptRow extends StatefulWidget {
  const BackgroundReceiptRow({super.key});

  @override
  State<BackgroundReceiptRow> createState() => _BackgroundReceiptRowState();
}

class _BackgroundReceiptRowState extends State<BackgroundReceiptRow> {
  Future<NseReceiptOutcome?>? _outcome;

  @override
  void initState() {
    super.initState();
    _outcome = IosSharedStore.lastReceiptOutcome();
  }

  @override
  Widget build(BuildContext context) {
    final t = DesignTokens.of(context);
    return FutureBuilder<NseReceiptOutcome?>(
      future: _outcome,
      builder: (context, snapshot) {
        final outcome = snapshot.data;
        if (outcome == null) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.fromLTRB(14, 16, 14, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Background delivery receipt',
                style: TextStyle(fontSize: 12, color: t.textMuted),
              ),
              const SizedBox(height: 4),
              Text(
                '${outcome.delivered ? 'Sent' : 'Not sent'} — ${outcome.summary}',
                style: TextStyle(fontSize: 12, color: t.text, height: 1.5),
              ),
              const SizedBox(height: 4),
              Text(
                _explain(outcome),
                style: TextStyle(fontSize: 12, color: t.textMuted, height: 1.5),
              ),
            ],
          ),
        );
      },
    );
  }

  /// Plain-language reading of the stage tag, so the row is useful to the user
  /// and not only to a developer reading the source.
  String _explain(NseReceiptOutcome outcome) {
    if (outcome.delivered) {
      return 'The last message that arrived while Chat was closed told its '
          'sender it had been delivered.';
    }
    switch (outcome.stage) {
      case 'skiptor':
        return 'Skipped on purpose: built-in Tor is on, and this step has no '
            'Tor transport, so sending it would expose your IP address. The '
            'sender sees "delivered" when you next open Chat.';
      case 'nopayload':
        return 'That push carried no sealed copy to work from (usually a large '
            'message). The sender sees "delivered" when you next open Chat.';
      case 'nopeerkeys':
        return "This device hasn't learned the sender's keys yet — it does so "
            'the first time you exchange messages with Chat open.';
      case 'blocked':
        return 'That conversation is blocked, so no receipt was sent.';
      default:
        return 'The sender sees "delivered" when you next open Chat.';
    }
  }
}
