import 'package:flutter/material.dart';

import '../../app/design_tokens.dart';
import '../../app/theme.dart';

/// Neutral branded splash shown at cold start while a returning user's session
/// and native MLS store load. It replaces the old flash of the signed-out
/// [WelcomeScreen] (which looked like the user had been logged out and was
/// being "checked"). The router starts here when the cached session-exists
/// flag is set; [NanbApp] navigates on to the chat list once MLS init finishes
/// — or back to /welcome if the session turns out to be gone.
class ResumingScreen extends StatelessWidget {
  const ResumingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final t = DesignTokens.of(context);
    return Scaffold(
      backgroundColor: t.bg,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Chat',
              style: monoStyle(fontSize: 14, color: t.accent, letterSpacing: 4),
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2, color: t.accent),
            ),
          ],
        ),
      ),
    );
  }
}
