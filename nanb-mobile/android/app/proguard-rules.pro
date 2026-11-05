# App-level R8/ProGuard keep rules for the release build.

# ── flutter_local_notifications ─────────────────────────────────────────────
# Its cancel()/scheduling code serialises a notification cache with Gson, which
# uses `new TypeToken<...>(){}`. R8 (full mode) strips the generic *Signature*
# attribute, so Gson throws `IllegalStateException: TypeToken must be created
# with a type argument` at runtime — which, in showCall()'s cancel-before-post,
# would abort the post and leave a closed device silent. Keep the plugin classes
# and the generic signatures so Gson can read the type arguments.
-keep class com.dexterous.** { *; }
-keepattributes Signature
-keepattributes *Annotation*
-keepattributes InnerClasses
-keepattributes EnclosingMethod

# ── Gson (transitively used by flutter_local_notifications) ──────────────────
-keep class com.google.gson.reflect.TypeToken { *; }
-keep class * extends com.google.gson.reflect.TypeToken
-keep public class * implements java.lang.reflect.Type
-keepclassmembers,allowobfuscation class * {
  @com.google.gson.annotations.SerializedName <fields>;
}
