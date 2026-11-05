import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../app/design_tokens.dart';

/// Preview an image or animated GIF and return its caption only on Send.
class MediaCaptionScreen extends StatefulWidget {
  const MediaCaptionScreen({
    super.key,
    this.bytes,
    this.preview,
    this.title = 'Send image',
    this.initialCaption = '',
  }) : assert(bytes != null || preview != null,
            'give either image bytes or a custom preview');

  /// Image/GIF bytes to preview. Null when [preview] is supplied instead.
  final Uint8List? bytes;

  /// Custom preview for media that isn't an inline image (a file or a video).
  final Widget? preview;
  final String title;
  final String initialCaption;

  @override
  State<MediaCaptionScreen> createState() => _MediaCaptionScreenState();
}

class _MediaCaptionScreenState extends State<MediaCaptionScreen> {
  late final _caption = TextEditingController(text: widget.initialCaption);

  @override
  void dispose() {
    _caption.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = DesignTokens.of(context);
    return Scaffold(
      backgroundColor: t.surface,
      appBar: AppBar(
        title: Text(widget.title),
        leading: IconButton(
          tooltip: 'Cancel',
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Center(
                child: widget.preview ??
                    Image.memory(
                      widget.bytes!,
                      fit: BoxFit.contain,
                      errorBuilder: (context, error, stackTrace) =>
                          const Text('Preview unavailable'),
                    ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _caption,
                      keyboardType: TextInputType.multiline,
                      textInputAction: TextInputAction.newline,
                      textCapitalization: TextCapitalization.sentences,
                      minLines: 1,
                      maxLines: 6,
                      style: TextStyle(color: t.text),
                      decoration: InputDecoration(
                        hintText: 'Add a caption…',
                        filled: true,
                        fillColor: t.surfaceAlt,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    tooltip: 'Send',
                    style: IconButton.styleFrom(
                      backgroundColor: t.accent,
                      foregroundColor: t.accentOn,
                      minimumSize: const Size(48, 48),
                    ),
                    onPressed: () =>
                        Navigator.of(context).pop(_caption.text.trim()),
                    icon: const Icon(Icons.send),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
