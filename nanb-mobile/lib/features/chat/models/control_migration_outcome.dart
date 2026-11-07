/// What happened when a control send tried the all-devices MLS migration of a
/// multi-device 1:1 (see `ControlSender.sendControl`).
enum ControlMigrationOutcome {
  /// The group was built with every device of both accounts and the control was
  /// already delivered inside it.
  migrated,

  /// A sibling device of ours is the designated initiator. This device must not
  /// build a group of its own (it would fork the chat) and sends on ratchet.
  deferToSibling,

  /// Not a ratchet 1:1, or one confirmed to have a single device on each side: the
  /// normal single-peer path applies.
  notApplicable,

  /// A group holding every device couldn't be built right now (a lookup failed,
  /// or the peer has no packages). Stay on ratchet rather than build a group that
  /// leaves devices out.
  stayOnRatchet,
}
