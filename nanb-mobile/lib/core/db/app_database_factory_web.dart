import 'app_database.dart';
import 'web/app_database_web.dart';
import 'web/indexed_db_web_db_store.dart';

/// Browser: the in-memory database persisted to encrypted IndexedDB.
AppDatabase createAppDatabase() =>
    AppDatabaseWeb(store: IndexedDbWebDbStore());
