#!/bin/bash
set -euo pipefail

# Builds CoreCrypto for iOS (device + simulator) and assembles an
# XCFramework linked from the Runner target.

CORE_CRYPTO_DIR="$(dirname "$0")/../native/core-crypto"
OUTPUT_DIR="$(dirname "$0")/Runner/CoreCrypto.xcframework"

if [ ! -d "$CORE_CRYPTO_DIR" ]; then
  echo "native/core-crypto not initialized. Run: git submodule update --init"
  exit 1
fi

cd "$CORE_CRYPTO_DIR"

# Device (arm64)
cargo build --release --target aarch64-apple-ios
# Simulator (Intel)
cargo build --release --target x86_64-apple-ios
# Simulator (Apple Silicon)
cargo build --release --target aarch64-apple-ios-sim

# Lipo the two simulator slices into one fat library.
mkdir -p target/sim-fat
lipo -create \
  target/x86_64-apple-ios/release/libcore_crypto_ffi.a \
  target/aarch64-apple-ios-sim/release/libcore_crypto_ffi.a \
  -output target/sim-fat/libcore_crypto_ffi.a

# Build the XCFramework.
rm -rf "$OUTPUT_DIR"
xcodebuild -create-xcframework \
  -library target/aarch64-apple-ios/release/libcore_crypto_ffi.a \
  -library target/sim-fat/libcore_crypto_ffi.a \
  -output "$OUTPUT_DIR"

# Regenerate Swift UniFFI bindings.
cargo run --features uniffi/cli --bin uniffi-bindgen -- generate \
  --library target/aarch64-apple-ios/release/libcore_crypto_ffi.a \
  --language swift \
  --out-dir "$(dirname "$0")/Runner"

echo "iOS native build complete: $OUTPUT_DIR"
