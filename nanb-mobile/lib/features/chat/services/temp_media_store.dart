import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Manages decrypted-media temp files so they never outlive the message they
/// belong to.
///
/// Viewing received media forces the decrypted bytes briefly onto disk: the OS
/// video/attachment openers and the `video_thumbnail` decoder all take a file
/// PATH, not an in-memory buffer. In an E2E-encrypted, disappearing-message app
/// those plaintext copies must be reclaimed when the message is deleted or
/// expires — otherwise a "deleted" photo/video/document lingers in the temp dir
/// until the OS happens to evict it.
///
/// This is the single authority for (a) NAMING every such file under one
/// sweepable prefix and (b) REMOVING them: per-message on delete/expiry via
/// [deleteForEnvelope], and wholesale on sign-out / at boot via [sweepAll]. It
/// complements `MediaCache` (RAM) — that caches the same bytes in memory; this
/// owns their on-disk shadow.
abstract interface class TempMediaStore {
  /// Reserves a temp-file path for decrypted media tied to [envelopeId]. The
  /// caller writes the bytes there and hands the path to the OS / decoder. The
  /// path lives under a shared, sweepable prefix and is tagged with
  /// [envelopeId] so [deleteForEnvelope] / [sweepAll] can reclaim it even if
  /// the writing widget is killed before its own cleanup. [label] carries the
  /// kind + extension (e.g. `video.mp4`, or an opened attachment's sanitized
  /// filename) so the OS picks the right viewer.
  Future<String> allocate({required String envelopeId, required String label});

  /// Deletes every temp-media file tagged with [envelopeId]. Called when the
  /// message is deleted (for me / for everyone), its chat is cleared, or it
  /// expires. Best-effort; never throws.
  Future<void> deleteForEnvelope(String envelopeId);

  /// Deletes ALL temp-media files this store owns. Called on sign-out / local
  /// wipe and at boot (any file present then is a straggler from a prior
  /// session). Best-effort; never throws.
  Future<void> sweepAll();
}

/// Production implementation backed by `getTemporaryDirectory()`. Excluded from
/// unit-test coverage (third-party I/O glue per project policy); the contract
/// is covered by tests against this class running over an injected temp dir.
class TempMediaStoreImpl implements TempMediaStore {
  TempMediaStoreImpl({Future<Directory> Function()? tempDirProvider})
      : _tempDirProvider = tempDirProvider ?? getTemporaryDirectory;

  final Future<Directory> Function() _tempDirProvider;

  /// Shared basename prefix for every decrypted-media temp file. Kept distinct
  /// from other `nanb-*` temp files (e.g. call tones) so [sweepAll] only ever
  /// removes media the user has viewed — never unrelated app temp files.
  static const String filePrefix = 'nanb-tmpmedia-';

  /// Separates the envelope tag from the label. Two chars that never occur in a
  /// server envelope id (base64url / hex / uuid), so they unambiguously
  /// terminate the id when [deleteForEnvelope] prefix-matches.
  static const String _delimiter = '__';

  /// Basename for a file tagged with [envelopeId] — the single source of truth
  /// for the naming the delete/sweep matchers rely on.
  static String basenameFor(String envelopeId, String label) =>
      '$filePrefix$envelopeId$_delimiter$label';

  @override
  Future<String> allocate({
    required String envelopeId,
    required String label,
  }) async {
    final dir = await _tempDirProvider();
    return p.join(dir.path, basenameFor(envelopeId, label));
  }

  @override
  Future<void> deleteForEnvelope(String envelopeId) => _deleteWhere(
        (name) => name.startsWith('$filePrefix$envelopeId$_delimiter'),
      );

  @override
  Future<void> sweepAll() => _deleteWhere((name) => name.startsWith(filePrefix));

  Future<void> _deleteWhere(bool Function(String basename) match) async {
    try {
      final dir = await _tempDirProvider();
      if (!dir.existsSync()) return;
      for (final entry in dir.listSync()) {
        if (entry is! File) continue;
        if (!match(p.basename(entry.path))) continue;
        try {
          await entry.delete();
        } catch (_) {/* best-effort per file */}
      }
    } catch (_) {/* best-effort sweep */}
  }
}

/// In-memory variant for tests: records the calls instead of touching disk, so
/// the notifier's cleanup wiring can be asserted without a real temp dir. The
/// on-disk contract is covered against [TempMediaStoreImpl] over a temp dir.
class TempMediaStoreInMemory implements TempMediaStore {
  /// Paths handed out by [allocate], in order.
  final List<String> allocated = <String>[];

  /// Envelope ids passed to [deleteForEnvelope], in order.
  final List<String> deletedEnvelopes = <String>[];

  /// Number of [sweepAll] calls.
  int sweepAllCount = 0;

  @override
  Future<String> allocate({
    required String envelopeId,
    required String label,
  }) async {
    final path = 'mem://$envelopeId/$label';
    allocated.add(path);
    return path;
  }

  @override
  Future<void> deleteForEnvelope(String envelopeId) async {
    deletedEnvelopes.add(envelopeId);
  }

  @override
  Future<void> sweepAll() async {
    sweepAllCount++;
  }
}
