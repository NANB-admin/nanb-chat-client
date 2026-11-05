/// Discriminator for chat-message rendering. Text is the default; image is
/// wired through the v1.x media pipeline (Plan 14). Voice, video, and file
/// land in Plan Attachments (2026-05-18). System (Plan C) renders as an
/// in-thread pill via `SystemLine`; body is a JSON payload with a top-level
/// `_system` key.
enum MessageKind {
  text,
  image,
  voice,
  video,
  file,
  system;

  static MessageKind fromName(String? name) {
    return MessageKind.values.firstWhere(
      (k) => k.name == name,
      orElse: () => MessageKind.text,
    );
  }
}
