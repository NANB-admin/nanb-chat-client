/// The kind of value a [ConversationStateField] carries on the wire.
enum StateFieldValueKind { flag, number, text }

/// One per-chat setting that converges across a user's own devices through the
/// `conversation_state` control. The enum [name] is the wire key; a key this
/// build does not know is ignored on decode (forward compatible).
enum ConversationStateField {
  muted(StateFieldValueKind.flag),
  pinned(StateFieldValueKind.flag),
  archived(StateFieldValueKind.flag),

  /// Per-chat disappearing timer in seconds; `-1` = follow the global default.
  disappearingTtl(StateFieldValueKind.number),
  blocked(StateFieldValueKind.flag),
  verified(StateFieldValueKind.flag),

  /// Per-chat background override: a preset name or `default`.
  background(StateFieldValueKind.text),

  /// Read position: serverTs (ms) of the newest message the user has read.
  readUpToMs(StateFieldValueKind.number),

  /// Clear-history watermark: serverTs (ms) of the newest message cleared.
  clearedAtMs(StateFieldValueKind.number);

  const ConversationStateField(this.valueKind);

  final StateFieldValueKind valueKind;

  String get wire => name;

  /// The field named [key], or null for an unknown (future) field.
  static ConversationStateField? fromWire(String key) {
    for (final f in ConversationStateField.values) {
      if (f.name == key) return f;
    }
    return null;
  }
}
