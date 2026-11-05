/// Table names, mirroring the SQL tables in `app_database_impl.dart`.
abstract final class WebTableNames {
  static const conversations = 'conversations';
  static const messages = 'messages';
  static const groupMembers = 'group_members';
  static const cryptoStates = 'conversation_crypto_states';
  static const deletedGroups = 'deleted_groups';

  static const all = <String>[
    conversations,
    messages,
    groupMembers,
    cryptoStates,
    deletedGroups,
  ];
}
