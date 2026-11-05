# Native MLS

The app uses Wire's prebuilt **CoreCrypto** Android library — added as a Maven dependency in `android/app/build.gradle.kts`:

```kotlin
implementation("com.wire:core-crypto-android:9.3.4")
```

The AAR ships:
- `libcore_crypto_ffi.so` for all 4 Android ABIs (arm64-v8a, armeabi-v7a, x86_64, x86)
- UniFFI-generated Kotlin bindings under the `com.wire.crypto` package

## History (why this dir is mostly empty)

Plan A originally pulled the CoreCrypto Rust source as a git submodule and cross-compiled via `cargo-ndk` + a Gradle build script. That worked in theory but Windows-host cross-compile to Android requires building OpenSSL from vendored source — which in turn needs a posix-style Perl with a full standard library (MSYS2 was the eventual fix) plus NASM, MSYS2 make, etc. After getting through Configure + early make, OpenSSL's Makefile hit further path-handling bugs on Windows that would have required more debugging.

Pivoted on 2026-05-15 to use Wire's prebuilt Maven AAR. The submodule, `build_corecrypto.gradle`, and the cargo-ndk pipeline have been removed; this README + an empty `native/` dir remain for historical context and as a marker for any future native-side work that doesn't go through the AAR (e.g., Proteus, custom crypto, etc.).

## iOS counterpart

Wire also publishes `WireCoreCrypto` to CocoaPods + Swift Package Manager. When the iOS half of Plan A is unblocked (Xcode access), depend on it the same way rather than running `ios/native_build.sh` (which builds from the now-removed Rust source).

## Bumping CoreCrypto

Edit the version string in `android/app/build.gradle.kts`. Plan B's Task 1 (CoreCrypto API survey) should be re-run after any bump since FFI signatures move between major versions.
