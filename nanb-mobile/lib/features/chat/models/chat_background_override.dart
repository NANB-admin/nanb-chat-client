import 'package:flutter/foundation.dart';

import '../../settings/models/chat_background.dart';

/// A per-chat background choice layered over the global default.
///
/// Three shapes: [useDefault] (follow the Appearance setting; also what "no
/// override" means), a synced [preset], or a device-local [photo] (a file on
/// THIS device, never synced).
@immutable
class ChatBackgroundOverride {
  const ChatBackgroundOverride.useDefault()
      : preset = null,
        photoPath = '';

  const ChatBackgroundOverride.preset(ChatBackground this.preset)
      : photoPath = '';

  const ChatBackgroundOverride.photo(this.photoPath)
      : preset = ChatBackground.custom;

  /// Wire value meaning "follow the global setting".
  static const String defaultWire = 'default';

  static const String _photoPrefix = 'photo:';

  final ChatBackground? preset;
  final String photoPath;

  bool get isDefault => preset == null;
  bool get isPhoto => preset == ChatBackground.custom;

  /// The value synced to other devices: `default` or a preset name; null for a
  /// photo (a file on one device cannot be synced).
  String? get syncWire {
    if (isDefault) return defaultWire;
    if (isPhoto) return null;
    return preset!.name;
  }

  /// Parses a synced wire value. Null for anything a device cannot apply from
  /// a sibling (unknown name, or the photo preset).
  static ChatBackgroundOverride? fromSyncWire(String wire) {
    if (wire == defaultWire) return const ChatBackgroundOverride.useDefault();
    for (final b in ChatBackground.values) {
      if (b.name == wire && b != ChatBackground.custom) {
        return ChatBackgroundOverride.preset(b);
      }
    }
    return null;
  }

  /// Local-storage form (a superset of the wire form: it can hold a photo).
  String toStorage() => isPhoto ? '$_photoPrefix$photoPath' : syncWire!;

  static ChatBackgroundOverride fromStorage(String raw) {
    if (raw.startsWith(_photoPrefix)) {
      final path = raw.substring(_photoPrefix.length);
      return path.isEmpty
          ? const ChatBackgroundOverride.useDefault()
          : ChatBackgroundOverride.photo(path);
    }
    return fromSyncWire(raw) ?? const ChatBackgroundOverride.useDefault();
  }

  @override
  bool operator ==(Object other) =>
      other is ChatBackgroundOverride &&
      other.preset == preset &&
      other.photoPath == photoPath;

  @override
  int get hashCode => Object.hash(preset, photoPath);
}
