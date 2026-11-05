import 'package:open_filex/open_filex.dart';

/// Outcome of asking the OS to open a file. Mapped from `open_filex`'s
/// `ResultType` so the rest of the app doesn't depend on plugin types.
enum FileOpenStatus {
  /// OS dispatched the file to an app successfully.
  ok,

  /// No installed app declared support for this MIME / extension.
  noAppToOpen,

  /// The file path we passed doesn't exist (programmer error if we just
  /// wrote it — usually means a sandbox / scoped-storage quirk).
  fileNotFound,

  /// User or OS denied access (Android scoped storage, iOS sandbox).
  permissionDenied,

  /// Any other failure surfaced by the plugin.
  error,
}

/// Result of a file-open attempt. Carries the plugin's optional human
/// message so callers can surface it in a snackbar.
class FileOpenResult {
  const FileOpenResult({required this.status, this.message});

  final FileOpenStatus status;
  final String? message;

  bool get success => status == FileOpenStatus.ok;
}

/// Test seam over `open_filex`. Production wires `OpenFilexFileOpener`;
/// tests inject a fake.
abstract class FileOpener {
  Future<FileOpenResult> open(String path);
}

/// Production seam backed by `open_filex`. Excluded from unit-test coverage
/// (third-party plugin glue) per project policy — the fake `FileOpener` in
/// `MediaFileOpener`'s test exercises the contract.
class OpenFilexFileOpener implements FileOpener {
  @override
  Future<FileOpenResult> open(String path) async {
    final r = await OpenFilex.open(path);
    final status = switch (r.type) {
      ResultType.done => FileOpenStatus.ok,
      ResultType.noAppToOpen => FileOpenStatus.noAppToOpen,
      ResultType.fileNotFound => FileOpenStatus.fileNotFound,
      ResultType.permissionDenied => FileOpenStatus.permissionDenied,
      ResultType.error => FileOpenStatus.error,
    };
    return FileOpenResult(status: status, message: r.message);
  }
}
