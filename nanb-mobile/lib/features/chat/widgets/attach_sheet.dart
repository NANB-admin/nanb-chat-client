import 'package:flutter/material.dart';

import '../../../app/design_tokens.dart';

/// `takePhoto` / `recordVideo` capture from the camera; `photo` / `video`
/// pick from the gallery; `file` is any document. (GIFs are sent from the
/// emoji panel's GIF tab, not here.)
enum AttachAction { takePhoto, recordVideo, photo, video, file }

/// Bottom sheet surfaced when the user taps the composer's paperclip.
/// Returns the selected [AttachAction] or null on dismiss.
class AttachSheet extends StatelessWidget {
  const AttachSheet({super.key});

  static Future<AttachAction?> show(BuildContext context) =>
      showModalBottomSheet<AttachAction>(
        context: context,
        builder: (_) => const AttachSheet(),
      );

  @override
  Widget build(BuildContext context) {
    final t = DesignTokens.of(context);
    // Material (not a plain Container/ColoredBox) so the ListTiles paint
    // their ink + any background on a Material ancestor — a bare colored box
    // trips a debug assertion in current Flutter.
    return Material(
      color: t.surface,
      child: SafeArea(
        // Scrollable so the sheet never overflows on short / landscape
        // viewports (the default modal sheet caps its height).
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
            // Camera capture first — the WhatsApp-style "shoot and send" path.
            ListTile(
              leading: Icon(Icons.photo_camera_outlined, color: t.text),
              title: const Text('Take photo'),
              onTap: () => Navigator.of(context).pop(AttachAction.takePhoto),
            ),
            ListTile(
              leading: Icon(Icons.videocam_outlined, color: t.text),
              title: const Text('Record video'),
              onTap: () => Navigator.of(context).pop(AttachAction.recordVideo),
            ),
            Divider(color: t.border, height: 8),
            ListTile(
              leading: Icon(Icons.image_outlined, color: t.text),
              title: const Text('Photo'),
              subtitle: const Text('From gallery'),
              onTap: () => Navigator.of(context).pop(AttachAction.photo),
            ),
            ListTile(
              leading: Icon(Icons.video_library_outlined, color: t.text),
              title: const Text('Video'),
              subtitle: const Text('From gallery'),
              onTap: () => Navigator.of(context).pop(AttachAction.video),
            ),
            ListTile(
              leading: Icon(Icons.insert_drive_file_outlined, color: t.text),
              title: const Text('File'),
              onTap: () => Navigator.of(context).pop(AttachAction.file),
            ),
            ],
          ),
        ),
      ),
    );
  }
}
