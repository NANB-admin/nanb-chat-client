import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

/// Asks before opening [url] in the system browser, then opens it.
///
/// The confirmation is deliberate for a privacy messenger: opening a link
/// leaves the app, so the site (and the network) sees the user's own IP and
/// browser — none of the app's Tor routing applies — and a link in a message is
/// the usual phishing vector. Showing the real address first lets the user
/// back out of a disguised one.
Future<void> confirmAndOpenLink(BuildContext context, String url) async {
  // Captured before the awaits so `context` isn't used across the async gaps.
  final messenger = ScaffoldMessenger.of(context);
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Open link?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(url, maxLines: 6, overflow: TextOverflow.ellipsis),
          const SizedBox(height: 12),
          const Text(
            'It opens in your browser, which is outside the app: the site can '
            'see your IP address.',
            style: TextStyle(fontSize: 12),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('Open'),
        ),
      ],
    ),
  );
  if (confirmed != true) return;

  try {
    final launched = await launchUrl(
      Uri.parse(url),
      mode: LaunchMode.externalApplication,
    );
    if (!launched) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Could not open the link.')),
      );
    }
  } catch (_) {
    messenger.showSnackBar(
      const SnackBar(content: Text('Could not open the link.')),
    );
  }
}
