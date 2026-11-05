# Local pod that vendors Wire's prebuilt CoreCrypto (MLS) XCFrameworks into the
# Runner app so `import WireCoreCrypto` works (ios/Runner/NanbCryptoChannel.swift,
# MlsClientHolder.swift, CapturingMlsTransport.swift, MlsExceptions.swift).
#
# Wire ships CoreCrypto for Apple platforms as two XCFrameworks attached to each
# GitHub release (NO CocoaPod exists):
#   - WireCoreCrypto.xcframework        — the ergonomic Swift wrapper (the module
#                                         you `import`; re-exports the uniffi one).
#   - WireCoreCryptoUniffi.xcframework  — the generated UniFFI bindings it wraps.
# Both are downloaded from the wireapp/core-crypto v9.3.4 release into frameworks/
# by .github/workflows/ios.yml (the prebuilt-artifact pattern, mirroring how
# NanbArti vendors libnanb_arti.a and how Android consumes the prebuilt Maven AAR).
#
# Version 9.3.4 is pinned to MATCH the Android `com.wire:core-crypto-android:9.3.4`
# AAR — the UniFFI FFI surface must be the same major on both platforms.
#
# The frameworks are arm64-only (release BuildSettings.xcconfig sets
# `EXCLUDED_ARCHS[sdk=*] = x86_64`): fine for real iPhones and Apple-silicon CI
# device builds; an Intel-Mac simulator build would not link.
Pod::Spec.new do |s|
  s.name             = 'NanbCoreCrypto'
  s.version          = '9.3.4'
  s.summary          = 'Wire CoreCrypto (MLS) XCFrameworks vendored for iOS.'
  s.description      = 'Prebuilt Wire CoreCrypto MLS binaries vendored into the Runner target for MLS parity with Android.'
  s.homepage         = 'https://github.com/wireapp/core-crypto'
  s.license          = { :type => 'GPL-3.0-only', :text => 'Wire core-crypto — see github.com/wireapp/core-crypto' }
  s.author           = { 'Wire Swiss GmbH' => 'opensource@wire.com' }
  # Placeholder source — unused for a local `:path =>` pod, but a valid podspec
  # requires it. The real binaries are fetched by CI into frameworks/.
  s.source           = { :git => 'https://github.com/wireapp/core-crypto.git', :tag => "v#{s.version}" }
  s.platform         = :ios, '15.0'

  s.vendored_frameworks = 'frameworks/WireCoreCrypto.xcframework',
                          'frameworks/WireCoreCryptoUniffi.xcframework'
  s.requires_arc        = true
end
