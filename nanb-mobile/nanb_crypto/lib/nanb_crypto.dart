/// Native CoreCrypto MLS channel for NANb Chat.
///
/// This package is Android-Kotlin only — there is no Dart API surface.
/// The app talks to it over `MethodChannel('nanb.crypto')` via
/// `CryptoBridgeNative`. The package exists so the channel registers as a
/// real Flutter plugin on every engine (foreground + FCM background
/// isolate) through `GeneratedPluginRegistrant`.
library;
