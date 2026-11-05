import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/core/db/sqlcipher_error_classifier.dart';

void main() {
  group('isUnreadableSqlcipherError', () {
    test('flags an undecryptable / wrong-key file (SQLite error 26)', () {
      expect(
        isUnreadableSqlcipherError(
            'DatabaseException(file is not a database (code 26 SQLITE_NOTADB))'),
        isTrue,
      );
      expect(
        isUnreadableSqlcipherError('file is encrypted or is not a database'),
        isTrue,
      );
      expect(isUnreadableSqlcipherError('SqliteException(code 26): ...'), isTrue);
    });

    test('is case-insensitive', () {
      expect(isUnreadableSqlcipherError('FILE IS NOT A DATABASE'), isTrue);
    });

    test('does NOT flag transient / operational failures', () {
      expect(isUnreadableSqlcipherError('database is locked (code 5)'), isFalse);
      expect(isUnreadableSqlcipherError('disk I/O error (code 10)'), isFalse);
      expect(isUnreadableSqlcipherError('no such table: messages'), isFalse);
      expect(
        isUnreadableSqlcipherError('attempt to write a readonly database'),
        isFalse,
      );
      expect(isUnreadableSqlcipherError(''), isFalse);
    });
  });
}
