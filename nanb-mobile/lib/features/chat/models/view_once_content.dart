import 'message_kind.dart';

/// What a view-once message showed, handed to the viewer exactly once. By the
/// time the viewer has it, the message itself has already been emptied.
class ViewOnceContent {
  const ViewOnceContent({
    required this.kind,
    required this.text,
    this.bytes,
    this.mime,
  });

  final MessageKind kind;

  /// The text of a text message, or a media message's caption.
  final String text;

  /// The media of a photo, video or voice message.
  final List<int>? bytes;

  final String? mime;
}
