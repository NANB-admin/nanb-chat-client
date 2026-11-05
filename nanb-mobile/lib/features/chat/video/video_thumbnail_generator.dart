import 'dart:typed_data';

import 'package:video_thumbnail/video_thumbnail.dart' as vt;

/// Test seam over the `video_thumbnail` plugin. Production wires
/// `PackageVideoThumbnailGenerator`; tests inject a fake.
abstract class VideoThumbnailGenerator {
  /// Returns a JPEG-encoded thumbnail (~480px wide) for the video at
  /// [videoPath], or null if the plugin failed to decode a frame.
  Future<Uint8List?> generate(String videoPath);
}

/// Production seam backed by `video_thumbnail`. Excluded from unit-test
/// coverage (third-party plugin glue) per project policy — the fake in
/// `VideoThumbnailLoader`'s test exercises the contract.
class PackageVideoThumbnailGenerator implements VideoThumbnailGenerator {
  @override
  Future<Uint8List?> generate(String videoPath) {
    return vt.VideoThumbnail.thumbnailData(
      video: videoPath,
      imageFormat: vt.ImageFormat.JPEG,
      maxWidth: 480,
      quality: 70,
    );
  }
}
