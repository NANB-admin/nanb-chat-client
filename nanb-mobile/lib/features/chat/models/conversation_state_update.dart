import 'conversation_state_field.dart';
import 'state_field_change.dart';

/// A sparse set of changed per-chat fields — the payload of the
/// `conversation_state` control. Only the fields that changed are present.
class ConversationStateUpdate {
  const ConversationStateUpdate(this.changes);

  final Map<ConversationStateField, StateFieldChange> changes;

  bool get isEmpty => changes.isEmpty;

  /// `{"muted": {"v": true, "t": 1730000000000, "d": "dev"}, ...}`.
  Map<String, Object> toJson() => {
        for (final e in changes.entries) e.key.wire: e.value.toJson(),
      };

  /// Decodes the `fields` map. Unknown fields and malformed entries are
  /// dropped; returns null when nothing usable remains.
  static ConversationStateUpdate? fromJson(Map<dynamic, dynamic> raw) {
    final changes = <ConversationStateField, StateFieldChange>{};
    for (final e in raw.entries) {
      final key = e.key;
      final value = e.value;
      if (key is! String || value is! Map) continue;
      final field = ConversationStateField.fromWire(key);
      if (field == null) continue;
      final change = StateFieldChange.fromJson(field, value);
      if (change != null) changes[field] = change;
    }
    return changes.isEmpty ? null : ConversationStateUpdate(changes);
  }
}
