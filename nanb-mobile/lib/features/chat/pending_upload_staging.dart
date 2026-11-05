import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/crypto/media_cipher.dart';

/// Disk staging for outbound media bytes so a restart mid-upload doesn't
/// force the user to re-pick the file. Each pending upload's plaintext is
/// AES-256-GCM encrypted under a freshly-generated per-upload key; the
/// ciphertext lives on disk under [stagingDir], and the raw key is
/// persisted alongside the outbox message row (the DB is SQLCipher-encrypted
/// so the key never lives plaintext anywhere). On next boot, the worker
/// reads the key back from the DB, decrypts the staging file, and resumes
/// the upload.
abstract class PendingUploadStaging {
  /// Encrypts [plaintext] with a fresh per-upload key and writes the
  /// wire-formatted ciphertext to a staging file keyed by [outboxId].
  /// Returns the raw key so the caller can persist it alongside the
  /// outbox row.
  Future<List<int>> writeEncrypted({
    required String outboxId,
    required List<int> plaintext,
  });

  /// Reads + decrypts the staging file for [outboxId] using [key]. Returns
  /// null when the file is missing, truncated, or fails GCM authentication
  /// (tampered or wrong key) — caller treats that as an unrecoverable
  /// staging entry and flips the outbox row to failed.
  Future<List<int>?> readDecrypted({
    required String outboxId,
    required List<int> key,
  });

  /// Best-effort delete of the staging file for [outboxId]. No-op if the
  /// file doesn't exist; never throws — staging cleanup is best-effort.
  Future<void> delete(String outboxId);

  /// Returns the outbox ids of every staging file currently on disk. Used
  /// by boot recovery to find files without a matching uploading=true row
  /// (orphans) so they can be swept.
  Future<List<String>> listStagedOutboxIds();
}

/// Production implementation backed by `getApplicationDocumentsDirectory()`.
/// Excluded from unit-test coverage (third-party I/O glue per project
/// policy); contract is covered by tests against [PendingUploadStagingImpl]
/// running over a temp dir.
class PendingUploadStagingImpl implements PendingUploadStaging {
  PendingUploadStagingImpl({Future<Directory> Function()? baseDirProvider})
      : _baseDirProvider = baseDirProvider ?? getApplicationDocumentsDirectory;

  final Future<Directory> Function() _baseDirProvider;

  static const String _subdir = 'pending-uploads';
  static const String _extension = '.bin';

  Future<Directory> _ensureDir() async {
    final base = await _baseDirProvider();
    final dir = Directory(p.join(base.path, _subdir));
    if (!dir.existsSync()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  String _filenameFor(String outboxId) => '$outboxId$_extension';

  @override
  Future<List<int>> writeEncrypted({
    required String outboxId,
    required List<int> plaintext,
  }) async {
    final dir = await _ensureDir();
    final result = await MediaCipher.encrypt(plaintext);
    final file = File(p.join(dir.path, _filenameFor(outboxId)));
    await file.writeAsBytes(result.ciphertext, flush: true);
    return result.key;
  }

  @override
  Future<List<int>?> readDecrypted({
    required String outboxId,
    required List<int> key,
  }) async {
    final dir = await _ensureDir();
    final file = File(p.join(dir.path, _filenameFor(outboxId)));
    if (!file.existsSync()) return null;
    try {
      final ciphertext = await file.readAsBytes();
      return await MediaCipher.decrypt(ciphertext: ciphertext, key: key);
    } catch (_) {
      // Truncated, tampered, or wrong-key — caller marks the row failed.
      return null;
    }
  }

  @override
  Future<void> delete(String outboxId) async {
    try {
      final dir = await _ensureDir();
      final file = File(p.join(dir.path, _filenameFor(outboxId)));
      if (file.existsSync()) await file.delete();
    } catch (_) {/* best-effort */}
  }

  @override
  Future<List<String>> listStagedOutboxIds() async {
    final dir = await _ensureDir();
    final entries = dir.listSync();
    final out = <String>[];
    for (final e in entries) {
      if (e is! File) continue;
      final name = p.basename(e.path);
      if (!name.endsWith(_extension)) continue;
      out.add(name.substring(0, name.length - _extension.length));
    }
    return out;
  }
}

/// In-memory staging usable in tests. Skips the AES round-trip and just
/// stores plaintext bytes keyed by outboxId — the contract tests in
/// `pending_upload_staging_test.dart` cover the real encrypt/decrypt path
/// against [PendingUploadStagingImpl] over a temp dir. Everywhere else the
/// notifier just needs a working staging seam, so the in-memory variant
/// keeps unit tests fast and disk-free.
class PendingUploadStagingInMemory implements PendingUploadStaging {
  final Map<String, List<int>> _files = {};
  final Map<String, List<int>> _keys = {};

  @override
  Future<List<int>> writeEncrypted({
    required String outboxId,
    required List<int> plaintext,
  }) async {
    final key = List<int>.generate(32, (i) => (outboxId.hashCode + i) & 0xff);
    _files[outboxId] = List<int>.from(plaintext);
    _keys[outboxId] = key;
    return key;
  }

  @override
  Future<List<int>?> readDecrypted({
    required String outboxId,
    required List<int> key,
  }) async {
    final storedKey = _keys[outboxId];
    if (storedKey == null) return null;
    for (var i = 0; i < storedKey.length; i++) {
      if (i >= key.length || storedKey[i] != key[i]) return null;
    }
    final stored = _files[outboxId];
    return stored == null ? null : List<int>.from(stored);
  }

  @override
  Future<void> delete(String outboxId) async {
    _files.remove(outboxId);
    _keys.remove(outboxId);
  }

  @override
  Future<List<String>> listStagedOutboxIds() async => _files.keys.toList();
}
