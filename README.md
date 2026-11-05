# NANb Chat

An end-to-end encrypted messenger for Android, iOS and the web. Messages use
MLS (RFC 9420) through [Wire CoreCrypto](https://github.com/wireapp/core-crypto),
and the app can reach the server over Tor.

- Website: <https://nanb.us>
- Web client: <https://chat.nanb.link>
- Licence: GPL-3.0-only (see [LICENSE](LICENSE), [NOTICE](NOTICE) and
  [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md))

## Source for each release

Every release is tagged `build-<number>` (for example `build-47`). The tag holds
exactly the source that build was made from.

## Layout

| Path | What it is |
|---|---|
| `nanb-mobile/` | The Flutter app: Android, iOS and web |
| `nanb-mobile/nanb_crypto/` | Native plugin that exposes CoreCrypto to Dart |
| `nanb-arti-ffi/` | Rust bridge that embeds the Arti Tor client |

The server is **not** part of this repository.

## Building

Requirements: Flutter (Dart `^3.11.5`), and for Android a JDK 17 and the Android
SDK. The Tor library needs a Rust toolchain (`nanb-arti-ffi/`), and iOS builds
need macOS with Xcode. CoreCrypto 9.3.4 is downloaded from Wire's releases at
build time.

```
cd nanb-mobile
flutter pub get
flutter test
flutter build apk --release        # Android
flutter build web --release        # Web
```

Release signing keys, store credentials and Firebase configuration are not in
this repository. Copy `nanb-mobile/android/app/google-services.json.template`
to `google-services.json` and fill in your own Firebase project to build with
push notifications.

## Contributing

Issues and pull requests are welcome. By submitting a contribution you agree to
license it under GPL-3.0-only. Please sign off your commits (`git commit -s`).

## Security

Please report vulnerabilities privately to admin@nanb.us rather than opening a
public issue.
