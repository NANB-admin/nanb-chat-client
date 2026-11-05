import '../models/account.dart';
import '../models/device.dart';
import '../models/device_kind.dart';
import '../models/envelope.dart';
import '../models/jwt_session.dart';
import '../models/report_request.dart';
import '../models/turn_credentials.dart';

/// Shape of a `POST /accounts` request payload.
class CreateAccountPayload {
  CreateAccountPayload({
    required this.username,
    required this.identityPubKey,
    required this.devicePubKey,
    required this.signedClaim,
    required this.keyPackages,
    this.x25519PubKey = const [],
    this.deviceDisplayName,
  });

  final String username;
  final List<int> identityPubKey;
  final List<int> x25519PubKey;
  final List<int> devicePubKey;
  final List<int> signedClaim;
  final List<List<int>> keyPackages;
  final String? deviceDisplayName;

  Map<String, dynamic> toJson() => {
        'username': username,
        'identity_pub_key': identityPubKey,
        if (x25519PubKey.isNotEmpty) 'x25519_pub_key': x25519PubKey,
        'device_pub_key': devicePubKey,
        'signed_claim': signedClaim,
        'key_packages': keyPackages,
        if (deviceDisplayName != null) 'device_display_name': deviceDisplayName,
      };
}

class ChallengeReply {
  ChallengeReply({required this.challenge, required this.expiresAt});
  final List<int> challenge;
  final DateTime expiresAt;
}

/// Shape of a `POST /devices/link` request. The already-signed-in primary
/// device sends the new device's own keys plus [signedLink] — the account
/// identity key's signature over [devicePubKey], proving the recovery-phrase
/// holder approved the link.
class LinkDevicePayload {
  LinkDevicePayload({
    required this.devicePubKey,
    required this.x25519PubKey,
    required this.signedLink,
    this.deviceDisplayName,
    this.keyPackages = const [],
    this.kind = DeviceKind.phone,
  });

  final List<int> devicePubKey;
  final List<int> x25519PubKey;
  final List<int> signedLink;
  final String? deviceDisplayName;
  final List<List<int>> keyPackages;

  /// Sent as `kind` ONLY for web; omitted (= phone) keeps the request
  /// byte-identical for older servers.
  final DeviceKind kind;

  Map<String, dynamic> toJson() => {
        'device_pub_key': devicePubKey,
        'x25519_pub_key': x25519PubKey,
        'signed_link': signedLink,
        if (deviceDisplayName != null) 'device_display_name': deviceDisplayName,
        'key_packages': keyPackages,
        if (kind != DeviceKind.phone) 'kind': kind.wire,
      };
}

class LinkDeviceResult {
  LinkDeviceResult({required this.deviceId, required this.linkedAt});
  final String deviceId;
  final String linkedAt;
}

/// Result of the unauthenticated `GET /devices/pending/{pubkey}` poll a
/// freshly-keyed device runs to discover its server identity once authorized.
class PendingDevice {
  const PendingDevice({
    required this.linked,
    this.accountId,
    this.deviceId,
    this.username,
  });

  final bool linked;
  final String? accountId;
  final String? deviceId;
  final String? username;

  factory PendingDevice.fromJson(Map<String, dynamic> json) => PendingDevice(
        linked: json['linked'] as bool? ?? false,
        accountId: json['account_id'] as String?,
        deviceId: json['device_id'] as String?,
        username: json['username'] as String?,
      );
}

class SubmitMessagePayload {
  SubmitMessagePayload({
    required this.conversationId,
    required this.envelopeType,
    required this.recipientAccountId,
    required this.recipientDeviceId,
    required this.ciphertext,
    this.ttlSeconds,
    this.pushKind,
  });

  final String conversationId;
  final String envelopeType;
  final String recipientAccountId;
  final String recipientDeviceId;
  final List<int> ciphertext;

  /// The sender's delete-messages-after preference, applied per envelope.
  /// The server only honors it DOWNWARD from its 30-day ceiling. Null →
  /// server default; control envelopes (mls_welcome etc.) deliberately
  /// send null so protocol state never expires early.
  final int? ttlSeconds;

  /// NON-encrypted hint that shapes the offline wakeup push. `'call'` makes a
  /// closed device ring (full-screen call notification) instead of showing a
  /// generic "new message". Null for normal messages. Content stays E2EE — this
  /// only tells the server which push style to send.
  final String? pushKind;

  Map<String, dynamic> toJson() => {
        'conversation_id': conversationId,
        'envelope_type': envelopeType,
        'recipient_account_id': recipientAccountId,
        'recipient_device_id': recipientDeviceId,
        'ciphertext': ciphertext,
        if (ttlSeconds != null) 'ttl_seconds': ttlSeconds,
        if (pushKind != null) 'push_kind': pushKind,
      };
}

class SubmitMessageResult {
  SubmitMessageResult({required this.envelopeId, required this.serverTs});
  final String envelopeId;
  final DateTime serverTs;
}

class MediaUploadInit {
  MediaUploadInit({
    required this.mediaId,
    required this.uploadUrl,
    required this.uploadExpiry,
  });
  final String mediaId;
  final String uploadUrl;
  final DateTime uploadExpiry;
}

class MediaDownload {
  MediaDownload({
    required this.downloadUrl,
    required this.downloadExpiry,
    required this.mimeType,
    required this.sizeBytes,
  });
  final String downloadUrl;
  final DateTime downloadExpiry;
  final String mimeType;
  final int sizeBytes;
}

/// Result of a single KeyPackage fetch from GET /accounts/{username}/key-package.
class FetchKeyPackageResult {
  const FetchKeyPackageResult({
    required this.keyPackage,
    required this.replenishNeeded,
    required this.remainingForUser,
  });

  /// Raw MLS KeyPackage bytes for the target user's device.
  final List<int> keyPackage;

  /// True when the server's pool for this user is running low and the caller
  /// should trigger a replenishment cycle (Plan B Task 15).
  final bool replenishNeeded;

  /// How many KeyPackages remain in the server pool after this fetch.
  final int remainingForUser;
}

/// One device's freshly-consumed KeyPackage, from
/// GET /accounts/{username}/key-packages. Used to add every device of an
/// account to an MLS group (full multi-device membership) — one leaf per device.
class DeviceKeyPackageResult {
  const DeviceKeyPackageResult({
    required this.deviceId,
    required this.keyPackage,
  });

  final String deviceId;
  final List<int> keyPackage;
}

/// Thrown by [ApiClient.lookupKeyPackage] when the peer account does not exist
/// (HTTP 404 with code `account_not_found`). [MlsMigrator] catches this to
/// stay on the ratchet path.
class AccountNotFoundException implements Exception {
  const AccountNotFoundException(this.message);
  final String message;

  @override
  String toString() => 'AccountNotFoundException: $message';
}

/// Thrown by [ApiClient.lookupKeyPackage] when the peer's KeyPackage pool is
/// empty (HTTP 410 with code `key_package_exhausted`). [MlsMigrator] catches
/// this to stay on the ratchet path.
class KeyPackageExhaustedException implements Exception {
  const KeyPackageExhaustedException(this.message);
  final String message;

  @override
  String toString() => 'KeyPackageExhaustedException: $message';
}

/// Result of GET /usernames/{username} — the pre-signup availability check.
/// Taken/held/invalid come back as a normal 200 result (not an [ApiError])
/// so the username screen can render inline feedback.
class UsernameAvailability {
  const UsernameAvailability({required this.available, this.reason});

  /// One of `invalid`, `taken`, `on_hold` when [available] is false.
  final String? reason;
  final bool available;

  factory UsernameAvailability.fromJson(Map<String, dynamic> json) =>
      UsernameAvailability(
        available: json['available'] as bool? ?? false,
        reason: json['reason'] as String?,
      );
}

/// Bearer-token-bearing client to nanb-server. Tests inject a fake.
abstract class ApiClient {
  /// Set the JWT used in `Authorization: Bearer ...`. Pass null to clear.
  void setBearerToken(String? jwt);

  Future<JwtSession> createAccount(CreateAccountPayload payload);

  /// GET /usernames/{username} — unauthenticated pre-signup availability
  /// check, so the user learns a name is taken/held BEFORE saving a
  /// recovery phrase. Throws [ApiError] only on transport/server failure.
  Future<UsernameAvailability> checkUsername(String username);

  /// Look up an account by username (e.g., "nass" without the leading `@`).
  /// Throws [ApiError] with code `account_not_found` (404) when missing,
  /// `username_invalid` (400) when malformed.
  Future<Account> lookupAccount(String username);

  /// GET /devices/{deviceId}/account — resolve an envelope's
  /// sender_device_id to its public account record. Lets the receiver of a
  /// message from an unknown peer identify the sender and seed the
  /// conversation instead of showing an "unknown peer" placeholder.
  Future<Account> lookupAccountByDevice(String deviceId);

  /// GET /accounts/by-id/{accountId} — resolve an account id to its public
  /// account record. Used by a self-synced Welcome: a linked device joins an
  /// MLS group knowing its peer only as an account id (parsed from the 1to1
  /// conversation id), and needs the @handle + keys to render it.
  Future<Account> lookupAccountById(String accountId);

  /// Lists every active device for the calling account. Auth-gated.
  Future<List<Device>> listDevices();

  /// POST /devices/me/capabilities — advertise that THIS device can open
  /// sealed-sender envelopes, so peers' senders are cleared to seal to it.
  /// Idempotent; called on connect once the client supports sealed receive.
  ///
  /// [x25519PubKey] re-publishes this device's CURRENT sealing key. Peers
  /// encrypt the sealed outer layer to whatever the server holds, so if our
  /// local keypair is ever regenerated while the device id stays the same, the
  /// published copy goes stale and we become silently unreachable: every peer
  /// keeps sealing to the dead key, we can't open a single envelope, and the
  /// receive path acks what it can't open — destroying the message while the
  /// SENDER sees a normal delivery. Sending it on every connect makes that
  /// self-healing. Empty leaves the stored key untouched.
  Future<void> reportSealedCapability({List<int> x25519PubKey = const []});

  /// POST /accounts/me/access-key — publish (or rotate) this account's
  /// unidentified-access-key commitment H(UAK) (sealed-sender Phase 2), so
  /// contacts can deposit sealed messages without revealing the sender.
  Future<void> reportAccessKeyCommitment(List<int> commitment);

  /// POST /messages/sealed — deposit a sealed envelope on the UNAUTHENTICATED
  /// path (no JWT, so the server never learns the sender), presenting the
  /// recipient's [accessKey] (UAK) for authorization. Throws ApiException on a
  /// 403 (recipient hasn't enabled it / wrong key) or 429 (rate limited) so the
  /// caller can fall back to the authenticated send.
  Future<SubmitMessageResult> submitSealedUnauthenticated(
      SubmitMessagePayload payload, List<int> accessKey);

  /// DELETE /devices/{deviceId} — revoke one of the calling account's OWN other
  /// devices (frees a device slot). The server rejects revoking the device the
  /// request is signed in on.
  Future<void> revokeDevice(String deviceId);

  /// PATCH /accounts/me — update the caller's display name and/or avatar URL.
  /// Null fields are left unchanged on the server. Auth-gated.
  Future<void> updateProfile({String? displayName, String? avatarUrl});

  /// POST /devices/link — authorize a brand-new device onto the caller's
  /// account. Auth-gated (the caller is the already-signed-in primary).
  Future<LinkDeviceResult> linkDevice(LinkDevicePayload payload);

  /// GET /devices/pending/{devicePubKeyHex} — unauthenticated poll a
  /// freshly-keyed device runs (by its own hex Ed25519 pub key) to learn
  /// whether the primary has authorized it, and if so its account + device id.
  Future<PendingDevice> getPendingDevice(String devicePubKeyHex);

  Future<ChallengeReply> requestChallenge({
    required String username,
    required String deviceId,
  });

  Future<JwtSession> submitSession({
    required String username,
    required String deviceId,
    required List<int> challenge,
    required List<int> signature,
  });

  /// Issues a challenge for the recovery-phrase restore flow. Keyed by
  /// username only — the restoring client doesn't know its device_id yet.
  Future<ChallengeReply> requestRestoreChallenge({required String username});

  /// Completes the restore. Returns the account_id + device_id + JWT, all
  /// of which the client previously did not know.
  Future<JwtSession> submitRestoreSession({
    required String username,
    required List<int> identityPubKey,
    required List<int> challenge,
    required List<int> signature,
    // When non-empty, restore MINTS a new device for this phone and revokes
    // the account's others ("this phone is now my account"). Empty → legacy
    // reuse behaviour (older server / caller).
    List<int> devicePubKey = const [],
    List<int> x25519PubKey = const [],
  });

  Future<SubmitMessageResult> submitMessage(SubmitMessagePayload payload);

  Future<List<Envelope>> catchupMessages({
    DateTime? since,
    int? limit,
  });

  Future<int> ackMessages(List<String> envelopeIds);

  Future<MediaUploadInit> initMediaUpload({
    required List<int> sha256,
    required int sizeBytes,
    required String mimeType,
    int? ttlSeconds,
    // OPTIONAL download audience (conversation participant account IDs). When
    // non-empty the server enforces per-object access to the uploader + these
    // accounts; omitted/empty keeps legacy open access. See MediaRecord authz.
    List<String>? authorizedAccountIds,
  });

  /// Returns a pointer the caller fetches via [getBytesFromUrl] to obtain the
  /// (still-E2EE) ciphertext bytes.
  ///
  /// Transport depends on whether the client routes over built-in Tor:
  ///   * **Off Tor**: a presigned/CloudFront download URL (CDN performance).
  ///   * **On Tor**: a URL pointing at the server's onion stream endpoint
  ///     (`/media/stream`), so the bytes stay on the no-exit onion path
  ///     instead of egressing to the CDN/S3 host through a Tor exit node.
  /// Either way [getBytesFromUrl] fetches the returned [MediaDownload.downloadUrl];
  /// callers don't branch on transport.
  Future<MediaDownload> getMedia(String mediaId);

  /// PUT raw bytes to a presigned S3 URL returned by `initMediaUpload`. The
  /// presigned URL carries its own auth — no bearer token. The caller's
  /// `mimeType` must match what was passed to `initMediaUpload` (S3 enforces).
  Future<void> putBytesToUrl({
    required String url,
    required List<int> bytes,
    required String mimeType,
  });

  /// GET raw bytes from a presigned S3 URL returned by `getMedia`. Used to
  /// fetch encrypted media blobs.
  Future<List<int>> getBytesFromUrl(String url);

  Future<void> registerPushToken({
    required String platform,
    required String token,
  });

  Future<void> deletePushToken();

  /// DELETE /accounts/me — server-side account deletion. Soft-deletes the
  /// account, revokes its devices, drops key packages / push tokens /
  /// pending envelopes, and places a 30-day hold on the username. Called by
  /// the settings "Delete account" flow before the local wipe.
  Future<void> deleteAccount();

  /// POST /reports — file a user-abuse report into the server moderation
  /// queue. Auth-gated: the server records the reporter from the JWT. The
  /// reporter chooses to forward recent messages from the reported user as
  /// evidence (see [ReportRequest.messages]).
  Future<void> reportUser(ReportRequest request);

  // ─── KeyPackage endpoints (Plan B Task 5 / 7) ─────────────────────────────

  /// POST /accounts/me/key-packages — upload `packages` to the server pool.
  /// Returns the count actually stored (may be less if the pool cap is hit).
  ///
  /// `reset: true` REPLACES this device's pool instead of adding to it: the
  /// server drops its unconsumed packages first. Set it only when the local
  /// MLS store was recreated, which destroys the private half of everything
  /// this device published. Appending in that case is not enough — the pool
  /// still reads as full to the replenisher and the server pops FIFO, so peers
  /// keep drawing dead packages and every Welcome built from one is
  /// undecryptable.
  Future<int> publishKeyPackages(List<List<int>> packages, {bool reset = false});

  /// GET /accounts/{username}/key-package — consume one KeyPackage from the
  /// server pool for `username`.
  ///
  /// Throws [ApiError] with code `account_not_found` (404) when the account
  /// does not exist, or `key_package_exhausted` (410) when the pool is empty.
  Future<FetchKeyPackageResult> lookupKeyPackage(String username);

  /// GET /accounts/{username}/key-packages — consume one KeyPackage per active
  /// device of `username`, for adding every device to an MLS group. Devices
  /// with no available package are omitted. Throws `account_not_found` (404)
  /// when the account doesn't exist.
  Future<List<DeviceKeyPackageResult>> lookupDeviceKeyPackages(String username);

  /// GET /accounts/me/key-packages/count — how many KeyPackages are currently
  /// stored for the calling account. Auth-gated.
  Future<int> keyPackageCount();

  /// GET /messages/by-id/{envelopeId} — fetches a single envelope addressed
  /// to the caller. Used by background-isolate push handlers + the iOS NSE
  /// (spec §11.3). Throws if not addressed to caller (server returns 404).
  Future<Envelope> getEnvelopeById(String envelopeId);

  /// GET /turn/credentials — short-lived WebRTC TURN credentials for a 1:1
  /// call. Auth-gated. Throws (ApiError) when TURN isn't configured server-side
  /// (503) — the caller then falls back to direct/STUN candidates.
  Future<TurnCredentials> fetchTurnCredentials();
}
