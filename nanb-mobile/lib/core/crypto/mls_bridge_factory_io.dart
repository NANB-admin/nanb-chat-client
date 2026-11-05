import 'crypto_bridge.dart';
import 'crypto_bridge_native.dart';

/// The MLS sub-bridge for Android/iOS: CoreCrypto over the `nanb.crypto`
/// method channel.
CryptoBridge createMlsBridge() => CryptoBridgeNative();
