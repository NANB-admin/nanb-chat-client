/// Whether a sqflite / SQLCipher failure message means the database file could
/// not be **decrypted or parsed** — a wrong/lost key or a corrupt file — as
/// opposed to a transient/operational failure (locked, disk I/O, no such table,
/// readonly). This is the signal the open path uses to decide whether to
/// recover (wipe+recreate or degrade) versus rethrow untouched.
///
/// SQLCipher surfaces an undecryptable file as SQLite error 26
/// ("file is not a database"); a wrong key on an encrypted file can also read as
/// "file is encrypted". The match is on the message text because the SQLite
/// extended result code isn't reliably plumbed through sqflite's exception.
bool isUnreadableSqlcipherError(String message) {
  final m = message.toLowerCase();
  return m.contains('not a database') ||
      m.contains('file is encrypted') ||
      m.contains('code 26');
}
