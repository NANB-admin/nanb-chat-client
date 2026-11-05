/// One file handed to us by the OS share sheet (Android `ACTION_SEND`
/// `EXTRA_STREAM`, iOS share-extension attachment).
///
/// The native side has already COPIED the bytes into a location this process
/// can read — Android's cache dir, iOS's App Group container — because neither
/// a `content://` URI nor another app's sandboxed file URL is readable from
/// Dart. [path] therefore always points at a plain local file that the sender
/// deletes once the share has been dispatched.
class SharedAttachment {
  const SharedAttachment({
    required this.path,
    required this.mimeType,
    required this.filename,
  });

  /// Absolute path to the local copy of the shared file.
  final String path;

  /// MIME type as reported by the OS (`ContentResolver.getType` /
  /// `UTType.preferredMIMEType`), falling back to a name-derived guess made
  /// natively. Drives which send path the share takes (image / video / file).
  final String mimeType;

  /// Original display name, preserved so a shared document arrives with the
  /// name the sender saw rather than the temp copy's name.
  final String filename;

  /// Decodes one entry of the platform channel's `attachments` list. Returns
  /// null when the map is missing a path — an attachment the native side
  /// failed to copy is skipped rather than sent as a broken bubble.
  static SharedAttachment? tryParse(Map<Object?, Object?> raw) {
    final path = raw['path'] as String?;
    if (path == null || path.isEmpty) return null;
    final name = raw['name'] as String?;
    final mime = raw['mime'] as String?;
    return SharedAttachment(
      path: path,
      mimeType: mime == null || mime.isEmpty ? 'application/octet-stream' : mime,
      filename: name == null || name.isEmpty ? 'shared-file' : name,
    );
  }
}
