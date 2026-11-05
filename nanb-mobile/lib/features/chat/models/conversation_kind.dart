/// Discriminator for 1:1 vs group conversations. New 1:1 chats keep
/// [oneToOne]; group chats land as [group] when created via
/// `CreateGroupScreen` or when a Welcome is received with a `group:`-
/// prefixed group_id (spec §10.1).
enum ConversationKind {
  oneToOne,
  group;

  static ConversationKind fromName(String s) {
    switch (s) {
      case 'oneToOne':
        return ConversationKind.oneToOne;
      case 'group':
        return ConversationKind.group;
      default:
        throw ArgumentError('unknown conversation kind: $s');
    }
  }
}
