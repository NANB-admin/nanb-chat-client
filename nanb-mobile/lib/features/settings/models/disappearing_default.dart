/// Default message-retention period for new conversations ("Delete messages
/// after" in Privacy). Per-conversation overrides live on
/// `ContactProfileScreen`; this is the global fallback. Defaults to one week.
///
/// There is deliberately no "off": messages always expire, the user only
/// chooses how fast. 30 days is the ceiling — it matches the server-side
/// envelope/media retention, so keeping ciphertext around longer locally
/// would outlive every other copy anyway.
enum DisappearingDefault {
  oneDay,
  oneWeek,
  thirtyDays;

  String get label {
    switch (this) {
      case DisappearingDefault.oneDay:
        return '24 hours';
      case DisappearingDefault.oneWeek:
        return '1 week';
      case DisappearingDefault.thirtyDays:
        return '30 days';
    }
  }

  /// Duration after which a message expires. Used by
  /// `ConversationsNotifier.runDisappearingSweep` to compute the cutoff.
  Duration get ttl {
    switch (this) {
      case DisappearingDefault.oneDay:
        return const Duration(days: 1);
      case DisappearingDefault.oneWeek:
        return const Duration(days: 7);
      case DisappearingDefault.thirtyDays:
        return const Duration(days: 30);
    }
  }

  /// Falls back to [thirtyDays] for unknown names — including the legacy
  /// `'off'` persisted by builds that still had an Off option.
  static DisappearingDefault fromName(String? name) {
    return DisappearingDefault.values.firstWhere(
      (m) => m.name == name,
      orElse: () => DisappearingDefault.thirtyDays,
    );
  }
}
