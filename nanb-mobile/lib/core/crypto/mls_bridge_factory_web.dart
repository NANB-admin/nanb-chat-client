import 'crypto_bridge.dart';
import 'crypto_bridge_web.dart';

/// The MLS sub-bridge for the browser: CoreCrypto WASM (`web/nanb_mls.js`).
CryptoBridge createMlsBridge() => CryptoBridgeWeb();
