# iOS build & sideload (GitHub Actions)

How the iOS app gets built and onto an iPhone. **iOS can only be compiled on
macOS**, and this repo is developed on Windows with no Xcode — so the build runs
on a GitHub-hosted macOS runner and produces an **unsigned IPA** you sideload
with a free Apple ID. There is no Mac in the loop for you; the runner is the Mac.

For bringing real MLS online on iOS (currently a ratchet-only stub) see
[`ios-mls-build.md`](ios-mls-build.md). This doc is only about the build/ship
pipeline.

---

## TL;DR — get an IPA

```bash
# 1. (only when the Rust/Arti or its deps changed) rebuild the Arti staticlib:
gh workflow run arti-ios.yml -R NANB-admin/nanb-mobile-chat-app

# 2. build the app — downloads the latest successful Arti artifact, compiles,
#    uploads an unsigned IPA:
gh workflow run ios.yml -R NANB-admin/nanb-mobile-chat-app

# 3. watch it, then download the artifact when green:
gh run watch -R NANB-admin/nanb-mobile-chat-app
gh run download <run-id> -n nanb-chat-unsigned-ipa -R NANB-admin/nanb-mobile-chat-app
```

Or trigger both from the repo's **Actions** tab → pick the workflow → **Run
workflow**. Then sideload `nanb-chat-unsigned.ipa` (see [Sideloading](#sideloading)).

---

## The two workflows

Both live in `.github/workflows/` and are **manual only** (`workflow_dispatch`):
macOS runner minutes bill at **10× on private repos** (~200 free macOS-min/month,
~10–20 min per app build), so nothing auto-builds on push.

| Workflow | Runner | What it does | When to run |
|---|---|---|---|
| **`arti-ios.yml`** | macOS | Builds the embedded-Tor **Arti** Rust FFI crate (`nanb-arti-ffi`) into a device-arm64 staticlib (`libnanb_arti.a`), uploaded as the `nanb-arti-ios-lib` artifact. | Only when the Rust/Arti code or its deps change (slow: ~15–30 min first run, cached after). |
| **`ios.yml`** | macOS | Builds the Flutter app → unsigned IPA, uploaded as `nanb-chat-unsigned-ipa`. | Every time you want a fresh iOS build. |

**Dependency:** `ios.yml` does **not** build Arti — it downloads the most recent
**successful** `arti-ios.yml` run's artifact (off `master`) and links it in. So
`arti-ios.yml` must have succeeded at least once before `ios.yml` will work, and
you only re-run `arti-ios.yml` when the Arti staticlib actually needs to change.
This prebuilt-artifact split (mirroring the Android C-tor AAR / CoreCrypto
approach) keeps the common app build fast.

### What `ios.yml` does, step by step

1. Checkout + set up Flutter (pinned `3.44.0`) + `flutter pub get`.
2. **Materialize `GoogleService-Info.plist`** from the `GOOGLE_SERVICE_INFO_PLIST_BASE64`
   secret (see [Secrets](#secrets)). The Runner target references it as a bundle
   resource, so the build **fails without it** — by design (FCM push needs it).
3. **Wire the Notification Service Extension + extra channel sources** into
   `Runner.xcodeproj` via `ios/ci/add_nse_target.rb` (see [Adding iOS native
   code](#adding-ios-native-code-channels--targets)).
4. **Fetch the prebuilt Arti staticlib** from the latest `arti-ios.yml` run into
   `ios/NanbArti/lib/`.
5. **`flutter build ios --release --no-codesign`** — the real signal: Dart→AOT,
   the Swift Runner target (our channels + Tor engine), the NSE, and every plugin
   pod (incl. Firebase/Messaging). Flutter generates the Podfile + runs
   `pod install` on first build.
6. **Package** the unsigned `Runner.app` into `Payload/…/nanb-chat-unsigned.ipa`
   and upload it as the `nanb-chat-unsigned-ipa` artifact.

---

## Secrets

Set under repo **Settings → Secrets and variables → Actions**:

| Secret | What | How to produce |
|---|---|---|
| `GOOGLE_SERVICE_INFO_PLIST_BASE64` | Base64 of `ios/Runner/GoogleService-Info.plist` (Firebase iOS config; gitignored like Android's `google-services.json`). | On a machine that has the plist: `base64 -i ios/Runner/GoogleService-Info.plist` (macOS) and paste the output as the secret. |

`GITHUB_TOKEN` is provided automatically (used to download the Arti artifact;
the workflow scopes it read-only via `permissions: contents/actions: read`).

No Apple signing certs live in CI — the IPA is unsigned on purpose.

---

## Adding iOS native code (channels / targets)

**This is the part that bites.** The project is edited on Windows with no Xcode,
so `Runner.xcodeproj/project.pbxproj` cannot be reliably hand-edited or validated
locally. The committed pbxproj is therefore **incomplete** — some Swift files
exist in `ios/Runner/` but are not referenced in it.

The blessed mechanism is **`ios/ci/add_nse_target.rb`**, run on the macOS runner
(step 3 above) via the `xcodeproj` gem, which ships with the CocoaPods toolchain.
It deterministically, and idempotently:

- adds the **`NanbNotificationService`** app-extension target + its embed phase, and
- adds the extra **channel source files** that `AppDelegate.swift` references but
  that aren't in the committed pbxproj, to the **Runner** target's Sources phase
  (`runner_extra_sources` — currently `SharedStoreChannel.swift` and
  `SecureScreenChannel.swift`).

**So: when you add a new Swift file that `AppDelegate` (or any Runner code)
references and you can't be sure it's correctly in the pbxproj, add its basename
to the `runner_extra_sources` list in `add_nse_target.rb`.** The script skips any
file already in the Sources phase, so it's safe even if the file *was* also
hand-added to the pbxproj — it never double-adds (which would be a "Multiple
commands produce" build error). If you forget, the build fails to link with an
undefined-symbol error for your channel.

> Channels already handled: `NanbCryptoChannel` and `TorChannel` are in the
> committed pbxproj; `SharedStoreChannel` and `SecureScreenChannel` are added by
> the script. `Hkdf.swift` is pure CryptoKit and only used by the (currently
> `#if false`'d) MLS files, so it needs no entry until MLS is wired up.

---

## Sideloading

The artifact is **unsigned** — not installable as-is. Re-sign it with a **free
Apple ID** using a sideloading tool, which gives a 7-day install (re-sign weekly,
or use a paid dev account for a year):

- **AltStore / SideStore** (the documented path): install AltServer on a
  PC/Mac (or SideStore on-device), then open `nanb-chat-unsigned.ipa` with it.
- **Sideloadly** is also in use here (`sideloadlydaemon.log` shows up locally) —
  same idea: plug in the iPhone, point it at the IPA, sign with your Apple ID.

After install, point the app at your server on the **Welcome screen → server icon
(top-right)** (same as the Android real-device step in
[`../../RUNNING.md`](../../RUNNING.md)).

---

## Gotchas

- **`ios.yml` fails at "Fetch prebuilt Arti staticlib"** → `arti-ios.yml` has
  never succeeded on `master` (or the artifact expired). Run `arti-ios.yml` first.
- **Build fails on a missing `GoogleService-Info.plist`** → the
  `GOOGLE_SERVICE_INFO_PLIST_BASE64` secret is unset/empty.
- **Undefined symbol for a Swift channel** → its file isn't in the Runner target;
  add it to `runner_extra_sources` in `add_nse_target.rb`.
- **A native change isn't on your phone** → you re-installed an *old* IPA. iOS
  changes require a fresh `ios.yml` run + re-sideload; there's no hot reload for
  a sideloaded release build.
- **`ios/native_build.sh` is stale/dead** (built CoreCrypto from a removed
  submodule) — don't use it; see [`ios-mls-build.md`](ios-mls-build.md).
