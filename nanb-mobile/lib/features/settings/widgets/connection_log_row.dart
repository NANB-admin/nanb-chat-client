import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app/design_tokens.dart';
import '../../../core/network/connection_log.dart';

/// Copies the content-free WebSocket event trail (see [ConnectionLog]) to the
/// clipboard so a flapping "Connecting..." banner can be diagnosed from a
/// release build, where every print is silenced.
class ConnectionLogRow extends StatelessWidget {
  const ConnectionLogRow({super.key});

  @override
  Widget build(BuildContext context) {
    final t = DesignTokens.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 0),
      child: Align(
        alignment: Alignment.centerLeft,
        child: TextButton(
          style: TextButton.styleFrom(foregroundColor: t.accent),
          onPressed: () async {
            final messenger = ScaffoldMessenger.of(context);
            final log = await ConnectionLog.instance.read();
            await Clipboard.setData(ClipboardData(text: log));
            messenger.showSnackBar(
                const SnackBar(content: Text('Connection log copied.')));
          },
          child: const Text('Copy connection log'),
        ),
      ),
    );
  }
}
