# google-services.json

A `google-services.json` file is REQUIRED at this path for the
`com.google.gms.google-services` Gradle plugin to succeed during the Android
build. The actual file is **gitignored** (it contains your Firebase project's
API key — see `.gitignore`).

## Setup

1. Create a Firebase project at https://console.firebase.google.com.
2. Add an Android app with package name `us.nanb.chat`.
3. Download the generated `google-services.json` from the Firebase console.
4. Place it next to this README at `nanb-mobile/android/app/google-services.json`.
5. **Do NOT commit it** — `.gitignore` blocks the path.

If you don't have a Firebase project yet (or are working offline), copy
`google-services.json.template` to `google-services.json` so the build can
proceed. With the placeholder values, `Firebase.initializeApp()` returns
successfully but `getToken()` returns null at runtime; the app gracefully
degrades — push notifications won't be delivered but the rest of the app
works. See `lib/core/push/push_token_provider_fcm.dart`.
