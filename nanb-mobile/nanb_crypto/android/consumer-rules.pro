# Consumer ProGuard rules — propagated into any app that depends on this
# plugin module (the NANb app inherits these in its R8 release pass).
#
# Wire CoreCrypto's Kotlin bindings are UniFFI-generated and talk to the
# native libcore_crypto_ffi.so through JNA, which resolves classes, fields,
# and callback methods via REFLECTION at runtime. R8 can't see those
# references, so an unconfigured release build strips/renames them and
# CoreCrypto dies on init with:
#   mlsIoException: Can't obtain peer field ID for class com.sun.jna.Pointer
#
# Keep all of JNA (incl. Structure field names — JNA maps them by name) and
# the generated CoreCrypto bindings.
-keep class com.sun.jna.** { *; }
-keep class * implements com.sun.jna.Library { *; }
-keep class * implements com.sun.jna.Callback { *; }
-keepclassmembers class * extends com.sun.jna.Structure { *; }
-keep class com.wire.crypto.** { *; }

# JNA references desktop-only AWT classes that don't exist on Android.
-dontwarn java.awt.**
-dontwarn com.sun.jna.platform.**

# ── Embedded Tor via Arti (libnanb_arti.so) ──────────────────────────────────
# The Rust side exports JNI functions named Java_us_nanb_crypto_ArtiNative_* and
# the JVM resolves them BY NAME at runtime, so R8 must not rename/strip the
# ArtiNative class or its native methods (else: UnsatisfiedLinkError on start).
-keep class us.nanb.crypto.ArtiNative { *; }
-keepclasseswithmembernames class * { native <methods>; }
