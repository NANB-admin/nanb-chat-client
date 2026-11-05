import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../chat/sticker_providers.dart';

/// The full local teardown shared by Settings → "Erase this device" /
/// "Delete account" and the welcome screen's "use a different account" guard.
///
/// Order matters: disconnect + DB-file wipe + identity-scoped caches first
/// (via `resetForAccountSwitch` — NOT bare `resetLocalDatabase`, which left the
/// old session's WS, JWT, and caches live until a process restart, so the first
/// sends after a switch went out as the previous user), then keys, session,
/// cached own-profile mirrors, and the account-scoped app-lock prefs.
///
/// After this returns the device is a clean slate — no session, no DB, no
/// crypto state — ready for a fresh create / restore / link. This is also what
/// guards the non-destructive sign-out: a manually-signed-out session keeps its
/// encrypted DB on disk, so any switch to a *different* account MUST wipe first,
/// or `connect()` would re-open the previous account's database.
Future<void> wipeLocalAccountState(WidgetRef ref) async {
  // EVERY step is independently best-effort. These run in order, but a failure
  // in an earlier one must NOT abort the rest — most importantly it must not
  // skip the session clear below. If, say, the native CoreCrypto wipe throws on
  // a particular device, an un-guarded chain would (a) leave the session record
  // on disk, so the user is still signed in, and (b) propagate the exception out
  // of "Erase this device", skipping its navigation to /welcome — the user taps
  // Erase and nothing visibly happens. So: swallow per step, always reach the
  // session teardown, and never throw out of this function.
  try {
    await ref.read(conversationsProvider).resetForAccountSwitch();
  } catch (_) {/* best-effort — keep tearing down */}
  try {
    await ref.read(cryptoBridgeProvider).wipe();
  } catch (_) {/* best-effort */}
  try {
    await ref.read(recoveryPhraseStorageProvider).clear();
  } catch (_) {/* best-effort */}
  // The session + signed-out gate clear is what actually signs the user out —
  // it must run even if the crypto/DB teardown above failed.
  try {
    await ref.read(sessionRepositoryProvider).clear();
  } catch (_) {/* best-effort */}
  // Own display name + avatar are cached in SecureStorage for the settings
  // card — stale values would label the NEXT account with the previous user's
  // profile.
  final storage = ref.read(secureStorageProvider);
  try {
    await storage.delete(myDisplayNameKey);
    await storage.delete(myAvatarKey);
  } catch (_) {/* best-effort */}
  ref.invalidate(myDisplayNameProvider);
  ref.invalidate(myAvatarProvider);
  // The cached TURN credential is account-scoped — coturn's ephemeral username
  // embeds the issuing account id — so a survivor would relay the NEXT account's
  // calls under the previous user's identity for the rest of its 12h TTL.
  try {
    await ref.read(turnCredentialsCacheProvider).clear();
  } catch (_) {/* best-effort */}
  // User-made stickers are plaintext images on disk (often saved from the old
  // account's chats), so they go with the rest of the account's local data.
  try {
    await ref.read(userStickerStoreProvider).clear();
  } catch (_) {/* best-effort */}
  // App lock is account-scoped: the passcode hash + lock prefs belong to the
  // account being wiped. Clear them and drop the in-memory lock flag so the
  // welcome screen (and the next account) isn't gated by the previous account's
  // passcode — the lock controller is a singleton that otherwise stays
  // locked=true until a process restart.
  try {
    await ref.read(passcodeServiceProvider).clear();
  } catch (_) {/* best-effort */}
  try {
    await ref.read(appPreferencesProvider).setPasscodeEnabled(false);
    await ref.read(appPreferencesProvider).setBiometricUnlock(false);
  } catch (_) {/* best-effort */}
  ref.read(appLockControllerProvider).unlock();
}
