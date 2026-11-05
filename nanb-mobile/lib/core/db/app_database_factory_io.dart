import 'app_database.dart';
import 'app_database_impl.dart';

/// Native platforms: the SQLCipher-backed database.
AppDatabase createAppDatabase() => AppDatabaseImpl();
