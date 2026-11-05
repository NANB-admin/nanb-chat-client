Browser MLS bridge: wraps @wireapp/core-crypto 9.3.4 (WASM, GPL-3.0) as `window.nanbMls`.
Build: `cd tool/web_mls && npm install && npm run build` (writes web/nanb_mls.js + web/core-crypto-ffi_bg.wasm, both committed).
Dart side: lib/core/crypto/crypto_bridge_web.dart (errors arrive as `nanb_mls_code=<code>;<msg>`).
Semantics mirror nanb_crypto/android (store key HKDF "nanb-corecrypto-store-v1", groupId == conversationId).
The WASM is fetched from the page base href; override with `window.nanbMlsWasmBase`.
