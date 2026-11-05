import 'dart:js_interop';

/// Shape returned by `nanbMls.addMember` / `addMembers`.
extension type NanbAddMemberResultJs._(JSObject _) implements JSObject {
  external JSUint8Array get welcome;
  external JSUint8Array get commit;
}
