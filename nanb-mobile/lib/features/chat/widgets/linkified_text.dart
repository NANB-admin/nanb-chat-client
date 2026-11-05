import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../models/link_span.dart';
import '../services/link_detector.dart';

/// Message text whose web links are underlined and tappable.
///
/// Plain text (no links) renders as an ordinary [Text]. The tap handling lives
/// on [TextSpan] recognizers, so a tap anywhere else in the bubble still falls
/// through to the bubble's own gestures (long-press menu, swipe to reply).
class LinkifiedText extends StatefulWidget {
  const LinkifiedText({
    super.key,
    required this.text,
    required this.style,
    required this.onOpenLink,
  });

  final String text;
  final TextStyle style;

  /// Called with the address of the link the user tapped.
  final ValueChanged<String> onOpenLink;

  @override
  State<LinkifiedText> createState() => _LinkifiedTextState();
}

class _LinkifiedTextState extends State<LinkifiedText> {
  List<LinkSpan> _links = const [];
  final List<TapGestureRecognizer> _recognizers = [];

  @override
  void initState() {
    super.initState();
    _detectLinks();
  }

  @override
  void didUpdateWidget(LinkifiedText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) _detectLinks();
  }

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  /// Re-scans the text. The recognizers are owned here (a [TextSpan] never
  /// disposes its recognizer), so the old ones go before the new ones exist.
  void _detectLinks() {
    _disposeRecognizers();
    _links = LinkDetector.find(widget.text);
    for (final link in _links) {
      // Reads `widget` at tap time, so a new callback needs no rebuild here.
      _recognizers.add(
        TapGestureRecognizer()..onTap = () => widget.onOpenLink(link.url),
      );
    }
  }

  void _disposeRecognizers() {
    for (final recognizer in _recognizers) {
      recognizer.dispose();
    }
    _recognizers.clear();
  }

  @override
  Widget build(BuildContext context) {
    if (_links.isEmpty) return Text(widget.text, style: widget.style);

    final linkStyle = TextStyle(
      decoration: TextDecoration.underline,
      decorationColor: widget.style.color,
    );
    final spans = <InlineSpan>[];
    var cursor = 0;
    for (var i = 0; i < _links.length; i++) {
      final link = _links[i];
      if (link.start > cursor) {
        spans.add(TextSpan(text: widget.text.substring(cursor, link.start)));
      }
      spans.add(TextSpan(
        text: widget.text.substring(link.start, link.end),
        style: linkStyle,
        recognizer: _recognizers[i],
      ));
      cursor = link.end;
    }
    if (cursor < widget.text.length) {
      spans.add(TextSpan(text: widget.text.substring(cursor)));
    }
    return Text.rich(TextSpan(style: widget.style, children: spans));
  }
}
