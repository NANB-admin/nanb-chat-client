import 'package:flutter/foundation.dart';

@immutable
class ApiError implements Exception {
  const ApiError({required this.code, required this.message, this.statusCode});

  final String code;
  final String message;
  final int? statusCode;

  factory ApiError.fromJson(Map<String, dynamic> json, {int? statusCode}) {
    // Most endpoints return {code, message} at the top level, but some wrap it
    // as {"error": {code, message}}. Accept either shape, and NEVER crash on a
    // missing/null code — an unguarded `as String` here turns a real server
    // error (e.g. "no key packages available") into a cryptic
    // "Null is not a subtype of String" that masks the actual failure.
    final body = json['error'] is Map
        ? Map<String, dynamic>.from(json['error'] as Map)
        : json;
    return ApiError(
      code: (body['code'] as String?) ?? 'unknown',
      message: (body['message'] as String?) ?? '',
      statusCode: statusCode,
    );
  }

  @override
  String toString() => 'ApiError($statusCode $code: $message)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ApiError &&
          code == other.code &&
          message == other.message &&
          statusCode == other.statusCode;

  @override
  int get hashCode => Object.hash(code, message, statusCode);
}
