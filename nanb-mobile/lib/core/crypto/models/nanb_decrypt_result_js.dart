import 'dart:js_interop';

/// Shape returned by `nanbMls.decryptAndInspect`.
extension type NanbDecryptResultJs._(JSObject _) implements JSObject {
  external JSUint8Array? get plaintext;
  external bool get selfRemoved;
  external int? get newEpoch;
  external String? get senderClientId;
}
