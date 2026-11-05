import 'conversation_state_field.dart';
import 'field_version.dart';

/// One field's new value plus its LWW [version]. Exactly one of [flag] /
/// [number] / [text] is set, matching the field's [StateFieldValueKind].
class StateFieldChange {
  const StateFieldChange.flag(bool value, this.version)
      : flag = value,
        number = null,
        text = null;

  const StateFieldChange.number(int value, this.version)
      : flag = null,
        number = value,
        text = null;

  const StateFieldChange.text(String value, this.version)
      : flag = null,
        number = null,
        text = value;

  final bool? flag;
  final int? number;
  final String? text;
  final FieldVersion version;

  /// Wire form: `{"v": <value>, "t": <timestampMs>, "d": <deviceId>}`.
  Map<String, Object> toJson() => {
        'v': (flag ?? number ?? text)!,
        't': version.timestampMs,
        'd': version.deviceId,
      };

  /// Parses [raw] for [field]; null when malformed or of the wrong value type.
  static StateFieldChange? fromJson(
      ConversationStateField field, Map<dynamic, dynamic> raw) {
    final v = raw['v'];
    final t = raw['t'];
    final d = raw['d'];
    if (t is! int || d is! String || d.isEmpty) return null;
    final version = FieldVersion(t, d);
    switch (field.valueKind) {
      case StateFieldValueKind.flag:
        return v is bool ? StateFieldChange.flag(v, version) : null;
      case StateFieldValueKind.number:
        return v is int ? StateFieldChange.number(v, version) : null;
      case StateFieldValueKind.text:
        return v is String && v.isNotEmpty
            ? StateFieldChange.text(v, version)
            : null;
    }
  }
}
