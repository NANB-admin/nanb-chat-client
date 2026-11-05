import 'package:flutter/material.dart';

import '../../../app/design_tokens.dart';

/// Preview several picked images/files and edit a caption for each one
/// (WhatsApp-style). Swipe between items; the caption field edits the item on
/// screen. Pops with one caption per item, in order, only on Send.
class MediaBatchCaptionScreen extends StatefulWidget {
  const MediaBatchCaptionScreen({
    super.key,
    required this.previews,
    this.initialFirstCaption = '',
    this.title = 'Send',
  });

  /// One preview widget per item (an image, or an attachment card).
  final List<Widget> previews;

  /// Pre-fills the FIRST item's caption (the text already typed in the composer).
  final String initialFirstCaption;
  final String title;

  @override
  State<MediaBatchCaptionScreen> createState() =>
      _MediaBatchCaptionScreenState();
}

class _MediaBatchCaptionScreenState extends State<MediaBatchCaptionScreen> {
  late final _pages = PageController();
  late final List<TextEditingController> _captions = [
    for (var i = 0; i < widget.previews.length; i++)
      TextEditingController(text: i == 0 ? widget.initialFirstCaption : ''),
  ];
  int _index = 0;

  @override
  void dispose() {
    _pages.dispose();
    for (final c in _captions) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = DesignTokens.of(context);
    final count = widget.previews.length;
    return Scaffold(
      backgroundColor: t.surface,
      appBar: AppBar(
        title: Text(count > 1 ? '${widget.title} (${_index + 1}/$count)' : widget.title),
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
              child: PageView.builder(
                controller: _pages,
                itemCount: count,
                onPageChanged: (i) => setState(() => _index = i),
                itemBuilder: (_, i) => Center(child: widget.previews[i]),
              ),
            ),
            if (count > 1)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    for (var i = 0; i < count; i++)
                      Container(
                        width: 7,
                        height: 7,
                        margin: const EdgeInsets.symmetric(horizontal: 3),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: i == _index ? t.accent : t.border,
                        ),
                      ),
                  ],
                ),
              ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    // Keyed per page so each item keeps its own text + focus.
                    child: TextField(
                      key: ValueKey('caption-$_index'),
                      controller: _captions[_index],
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
                    onPressed: () => Navigator.of(context)
                        .pop([for (final c in _captions) c.text.trim()]),
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
