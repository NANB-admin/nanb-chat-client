import 'package:flutter/foundation.dart';

/// What a web page says about itself in its `<head>` (Open Graph / Twitter card /
/// `<title>`), before any image has been downloaded.
@immutable
class PageMetadata {
  const PageMetadata({
    this.title = '',
    this.description = '',
    this.imageUrl,
  });

  final String title;
  final String description;

  /// Absolute address of the page's preview image, if it names one.
  final Uri? imageUrl;

  bool get isEmpty => title.isEmpty && description.isEmpty && imageUrl == null;

  @override
  bool operator ==(Object other) =>
      other is PageMetadata &&
      other.title == title &&
      other.description == description &&
      other.imageUrl == imageUrl;

  @override
  int get hashCode => Object.hash(title, description, imageUrl);

  @override
  String toString() => 'PageMetadata($title | $description | $imageUrl)';
}
