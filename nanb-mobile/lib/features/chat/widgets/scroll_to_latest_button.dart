import 'package:flutter/material.dart';

import '../../../app/design_tokens.dart';

/// Round down-arrow button pinned to the bottom-right of a thread that jumps
/// back to the newest message. Fades in when [visible].
class ScrollToLatestButton extends StatelessWidget {
  const ScrollToLatestButton({
    super.key,
    required this.visible,
    required this.onPressed,
  });

  final bool visible;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final t = DesignTokens.of(context);
    return IgnorePointer(
      ignoring: !visible,
      child: AnimatedOpacity(
        opacity: visible ? 1 : 0,
        duration: const Duration(milliseconds: 150),
        child: Material(
          color: t.surface,
          elevation: 3,
          shape: CircleBorder(side: BorderSide(color: t.border)),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onPressed,
            child: SizedBox(
              width: 40,
              height: 40,
              child: Icon(Icons.keyboard_arrow_down, color: t.text),
            ),
          ),
        ),
      ),
    );
  }
}
