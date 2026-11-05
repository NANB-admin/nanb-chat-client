import 'dart:convert';

/// Decodes a JSON value that carries raw bytes into a `List<int>`.
///
/// The Go server marshals every `[]byte` field as a **base64 string** (that's
/// `encoding/json`'s default for byte slices). Our own `toJson()` round-trips,
/// local DB snapshots, and test fixtures instead represent the same bytes as a
/// JSON **integer array**. Go's decoder accepts both forms, so the send side
/// has always worked; this lets the *receive* side accept both too — one parser
/// for the real wire format and for in-process round-trips.
///
/// `null` and the empty string both decode to an empty list (Go emits `null`
/// for a nil slice and `""` for an empty one).
List<int> bytesFromJson(Object? value) {
  if (value == null) return const [];
  if (value is String) {
    return value.isEmpty ? const [] : base64.decode(value);
  }
  if (value is List) return List<int>.from(value);
  throw FormatException(
    'expected a base64 string or byte array, got ${value.runtimeType}',
  );
}
