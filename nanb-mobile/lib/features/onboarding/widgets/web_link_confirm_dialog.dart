import 'package:flutter/material.dart';

/// Asks the user to confirm linking a WEB browser. A QR on a lookalike site is
/// a phishing vector, so a web link is never authorized without this prompt.
/// Resolves true only on an explicit "Link".
Future<bool> confirmWebLink(BuildContext context) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Link a web browser?'),
      content: const Text(
        'Link a web browser? It will be able to read your messages until you '
        'remove it or it expires in 30 days.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text('Link'),
        ),
      ],
    ),
  );
  return ok ?? false;
}
