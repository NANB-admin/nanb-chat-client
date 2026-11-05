# Local pod that vendors the prebuilt embedded-Arti Rust static library
# (libnanb_arti.a, built by .github/workflows/arti-ios.yml and fetched into
# lib/ by ios.yml) into the Runner app and exposes its C header as a
# Swift-importable module (`import NanbArti`).
#
# static_framework = true so the vendored *static* lib's symbols link into the
# app binary even though the Podfile uses use_frameworks! (dynamic) for
# everything else. Mirrors how `pod 'Tor'` currently supplies the C-tor binary.
Pod::Spec.new do |s|
  s.name             = 'NanbArti'
  s.version          = '0.1.0'
  s.summary          = 'Embedded Arti (Rust Tor) static library for iOS.'
  s.description      = 'C-ABI bridge to an embedded Arti Tor client (in-process SOCKS5).'
  s.homepage         = 'https://nanb.link'
  s.license          = { :type => 'Proprietary', :text => 'NANb internal' }
  s.author           = { 'NANb' => 'noreply@nanb.link' }
  # Placeholder source — unused for a local `:path =>` pod, but required to be a
  # valid podspec.
  s.source           = { :git => 'https://nanb.link/nanb-arti.git', :tag => s.version.to_s }
  s.platform         = :ios, '15.0'

  s.source_files        = 'include/**/*.h'
  s.public_header_files = 'include/**/*.h'
  s.vendored_libraries  = 'lib/libnanb_arti.a'
  s.static_framework    = true
  s.requires_arc        = true
  # System libs the Arti staticlib (tokio/rustls/ring) references on iOS:
  # Security (SecRandomCopyBytes for ring's RNG), SystemConfiguration (reachability
  # in some net crates), and libresolv (DNS resolver symbols). Link-time errors
  # ("undefined symbol _Sec.../_res_...") would tell us if more are needed.
  s.frameworks          = 'Security', 'SystemConfiguration'
  s.libraries           = 'resolv'
end
