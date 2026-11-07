import 'dart:js_interop';

import 'models/nanb_add_member_result_js.dart';
import 'models/nanb_decrypt_result_js.dart';

/// Typed view of `window.nanbMls` (built from tool/web_mls, loaded by
/// web/index.html). One member per JS function.
extension type NanbMlsJs._(JSObject _) implements JSObject {
  external JSPromise<JSAny?> open(String databaseName, JSUint8Array key);
  external JSPromise<JSAny?> ensureClient(String clientId);
  external JSPromise<JSAny?> close();
  external JSPromise<JSAny?> wipe();
  external JSPromise<JSBoolean> consumeStoreReset();
  external JSPromise<JSArray<JSUint8Array>> mintKeyPackages(int count);
  external JSPromise<JSString> createGroup(String conversationId);
  external JSPromise<NanbAddMemberResultJs> addMember(
    String groupId,
    JSUint8Array keyPackage,
  );
  external JSPromise<NanbAddMemberResultJs> addMembers(
    String groupId,
    JSArray<JSUint8Array> keyPackages,
  );
  external JSPromise<JSUint8Array> removeMember(
    String groupId,
    String targetDeviceId,
  );
  external JSPromise<JSString> processWelcome(JSUint8Array welcome);
  external JSPromise<JSAny?> processCommit(String groupId, JSUint8Array commit);
  external JSPromise<JSNumber> currentEpoch(String groupId);
  external JSPromise<JSArray<JSString>> groupMembers(String groupId);
  external JSPromise<JSUint8Array> encrypt(
    String groupId,
    JSUint8Array plaintext,
  );
  external JSPromise<NanbDecryptResultJs> decryptAndInspect(
    String groupId,
    JSUint8Array ciphertext,
  );
  external JSPromise<JSString> replaceGroup(
    String localGroupId,
    JSUint8Array foreignWelcome,
  );
  external JSPromise<JSAny?> wipeGroup(String groupId);
}

@JS('nanbMls')
external NanbMlsJs? get _nanbMls;

/// Waits for the deferred module script to publish `window.nanbMls`.
Future<NanbMlsJs> awaitNanbMls({
  Duration timeout = const Duration(seconds: 15),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (true) {
    final api = _nanbMls;
    if (api != null) return api;
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('window.nanbMls was not loaded (web/nanb_mls.js)');
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}
