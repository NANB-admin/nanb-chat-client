import 'models/web_db_snapshot.dart';
import 'models/web_db_write.dart';

/// Persistence backend for `AppDatabaseWeb`. The database keeps the whole
/// dataset in memory; a store only has to load it once at open and absorb
/// batched write-through mutations afterwards.
abstract class WebDbStore {
  /// Opens the backend (creating it if needed) and returns every persisted row.
  /// Throws [WebDbUnreadableException] when the stored data cannot be read
  /// (lost key, corruption).
  Future<WebDbSnapshot> loadAll();

  /// Applies [writes] in order as ONE atomic batch (a single IndexedDB
  /// transaction in the browser).
  Future<void> applyWrites(List<WebDbWrite> writes);

  /// Removes every persisted row but keeps the backend usable.
  Future<void> clear();

  /// Releases the backend handle. A later [loadAll] reopens it.
  Future<void> close();

  /// Removes the backend entirely (rows AND any key material), so the next
  /// [loadAll] starts from scratch. Backs `AppDatabase.deleteFile`.
  Future<void> destroy();
}

/// The persisted data exists but could not be decrypted or parsed.
class WebDbUnreadableException implements Exception {
  const WebDbUnreadableException(this.cause);

  final Object cause;

  @override
  String toString() => 'WebDbUnreadableException: $cause';
}
