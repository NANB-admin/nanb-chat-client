import 'dart:convert';

import 'package:flutter/foundation.dart';

/// The card shown under a message that contains a web link: the page's title and
/// description plus a small thumbnail. Built ONCE on the sender's device and sent
/// to the recipient inside the encrypted channel, so the recipient's phone never
/// contacts the site.
@immutable
class LinkPreview {
  const LinkPreview({
    required this.url,
    required this.title,
    this.description = '',
    this.thumbnail,
  });

  /// The link this card describes (one of the links in the message body).
  final String url;
  final String title;
  final String description;

  /// Small PNG, or null when the page had no usable image.
  final List<int>? thumbnail;

  Map<String, Object> toJson() => {
        'url': url,
        'title': title,
        if (description.isNotEmpty) 'desc': description,
        if (thumbnail != null && thumbnail!.isNotEmpty)
          'thumb': base64.encode(thumbnail!),
      };

  /// Null when [json] lacks a url/title or carries an undecodable thumbnail.
  static LinkPreview? fromJson(Object? json) {
    if (json is! Map) return null;
    final url = json['url'];
    final title = json['title'];
    if (url is! String || url.isEmpty) return null;
    if (title is! String || title.isEmpty) return null;
    final desc = json['desc'];
    final thumb = json['thumb'];
    List<int>? thumbnail;
    if (thumb is String && thumb.isNotEmpty) {
      try {
        thumbnail = base64.decode(thumb);
      } catch (_) {
        return null;
      }
    }
    return LinkPreview(
      url: url,
      title: title,
      description: desc is String ? desc : '',
      thumbnail: thumbnail,
    );
  }

  /// JSON text, for the database column.
  String encode() => jsonEncode(toJson());

  static LinkPreview? tryDecode(String? text) {
    if (text == null || text.isEmpty) return null;
    try {
      return fromJson(jsonDecode(text));
    } catch (_) {
      return null;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is LinkPreview &&
      other.url == url &&
      other.title == title &&
      other.description == description &&
      listEquals(other.thumbnail, thumbnail);

  @override
  int get hashCode => Object.hash(url, title, description, thumbnail?.length);
}
