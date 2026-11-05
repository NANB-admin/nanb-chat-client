import '../../settings/models/chat_background.dart';
import 'chat_background_override.dart';

/// The background a thread actually paints: the per-chat override when set,
/// otherwise the global Appearance default.
class EffectiveChatBackground {
  const EffectiveChatBackground(this.background, this.customPath);

  final ChatBackground background;
  final String customPath;

  static EffectiveChatBackground resolve(
    ChatBackgroundOverride override,
    ChatBackground globalBackground,
    String globalCustomPath,
  ) {
    if (override.isDefault) {
      return EffectiveChatBackground(globalBackground, globalCustomPath);
    }
    if (override.isPhoto) {
      return EffectiveChatBackground(ChatBackground.custom, override.photoPath);
    }
    return EffectiveChatBackground(override.preset!, '');
  }
}
