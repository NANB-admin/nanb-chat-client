import 'package:image_picker/image_picker.dart';

import '../media_pipeline.dart';
import '../models/message_kind.dart';

/// A photo the user picked for a group, ready to upload.
class PickedGroupPhoto {
  const PickedGroupPhoto(this.bytes, this.mimeType);
  final List<int> bytes;
  final String mimeType;
}

/// Picks a group photo from the gallery (down-scaled; it is shown as a small
/// circle) and uploads it as encrypted media.
class GroupPhotoPicker {
  GroupPhotoPicker(this._media, {ImagePicker? picker})
      : _picker = picker ?? ImagePicker();

  final MediaPipeline _media;
  final ImagePicker _picker;

  /// Null when the user cancels.
  Future<PickedGroupPhoto?> pick() async {
    final picked = await _picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 512,
      maxHeight: 512,
      imageQuality: 85,
    );
    if (picked == null) return null;
    return PickedGroupPhoto(
      await picked.readAsBytes(),
      picked.mimeType ?? 'image/jpeg',
    );
  }

  /// Encrypts + uploads [photo]; returns the descriptor JSON stored on the group.
  Future<String> upload(PickedGroupPhoto photo) async {
    final descriptor = await _media.upload(
      kind: MessageKind.image,
      plaintext: photo.bytes,
      mimeType: photo.mimeType,
    );
    return descriptor.toJson();
  }
}
