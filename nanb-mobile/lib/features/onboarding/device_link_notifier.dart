import 'package:flutter/foundation.dart' show kIsWeb;

import '../../core/crypto/crypto_bridge.dart';
import '../../core/models/device_kind.dart';
import '../../core/models/jwt_session.dart';
import '../../core/network/api_client.dart';
import 'device_link_payload.dart';
import 'session_repository.dart';

/// Thrown by the new-device claim flow when the server says a device is linked
/// but omits the identity fields needed to open a session.
class IncompleteLinkException implements Exception {
  const IncompleteLinkException(this.message);
  final String message;
  @override
  String toString() => 'IncompleteLinkException: $message';
}

/// Drives multi-device linking, both ends of the QR handshake:
///
/// **Primary device** (already signed in, holds the account identity key):
/// scans the new device's QR and calls [authorize] — signs the new device's
/// Ed25519 pub key with the account identity key and POSTs `/devices/link`.
///
/// **New device** (fresh install, no recovery phrase): calls
/// [prepareNewDevice] to mint its OWN device keypair (Ed25519 for session auth
/// + X25519 for the ratchet — NOT phrase-derived) and get the QR string, then
/// polls [pollPending] until the primary authorizes it, then [completeClaim]
/// to run the normal session challenge/response with its device key and come
/// online.
class DeviceLinkNotifier {
  DeviceLinkNotifier({
    required ApiClient apiClient,
    required CryptoBridge crypto,
    required SessionRepository sessions,
  })  : _api = apiClient,
        _crypto = crypto,
        _sessions = sessions;

  final ApiClient _api;
  final CryptoBridge _crypto;
  final SessionRepository _sessions;

  // ─── Primary device ───────────────────────────────────────────────────────

  /// Authorizes the scanned [payload] onto the current account. Signs the new
  /// device's Ed25519 pub key with the account identity key (proving the
  /// recovery-phrase holder approved it) and registers it server-side.
  Future<LinkDeviceResult> authorize(
    DeviceLinkPayload payload, {
    String? displayName,
  }) async {
    final identity = await _crypto.currentIdentity();
    if (identity == null) {
      throw StateError('cannot authorize a link without a local identity');
    }
    final signedLink = await _crypto.signWithIdentity(identity, payload.publicKey);
    return _api.linkDevice(
      LinkDevicePayload(
        devicePubKey: payload.publicKey,
        x25519PubKey: payload.x25519PublicKey,
        signedLink: signedLink,
        deviceDisplayName: displayName,
        kind: payload.kind,
        // The new device publishes its own key packages once it's online.
        keyPackages: const [],
      ),
    );
  }

  // ─── New device ─────────────────────────────────────────────────────────────

  /// Mints (or reuses) this device's own keypair and returns the QR string to
  /// display + the hex Ed25519 pub key to poll the link status by.
  Future<({String qr, String pubKeyHex})> prepareNewDevice() async {
    // A linked device's keys are its OWN, random — never derived from the
    // account recovery phrase (which it does not have). Reuse an existing
    // local identity if one is already present (e.g. the user backgrounded
    // mid-link) so the QR stays stable.
    var identity = await _crypto.currentIdentity();
    identity ??= await _crypto.generateIdentity();

    final qr = DeviceLinkPayload.buildUri(
      handleId: identity.id,
      publicKey: identity.publicKey,
      x25519PublicKey: identity.x25519PublicKey,
      // Only a browser identifies itself; mobile QR bytes stay unchanged.
      kind: kIsWeb ? DeviceKind.web : DeviceKind.phone,
    );
    return (qr: qr, pubKeyHex: _hex(identity.publicKey));
  }

  /// One poll of the link status, keyed by this device's hex Ed25519 pub key.
  Future<PendingDevice> pollPending(String pubKeyHex) =>
      _api.getPendingDevice(pubKeyHex);

  /// Completes the claim once [pending] reports linked: runs the session
  /// challenge/response with this device's own key, persists the session,
  /// initializes MLS, and best-effort publishes an initial KeyPackage batch.
  Future<JwtSession> completeClaim(PendingDevice pending) async {
    final accountId = pending.accountId;
    final deviceId = pending.deviceId;
    final username = pending.username;
    if (!pending.linked ||
        accountId == null ||
        deviceId == null ||
        username == null) {
      throw const IncompleteLinkException('link not ready');
    }

    final identity = await _crypto.currentIdentity();
    if (identity == null) {
      throw const IncompleteLinkException('local device identity missing');
    }

    // Open the CoreCrypto store now that the identity seed is on disk.
    // BEST-EFFORT for the same reason as sign-up/restore: a store that won't
    // open must not fail the link. The MLS block further down already treats
    // its own failures that way and re-runs mlsInit as the retry.
    try {
      await _crypto.mlsInit();
    } catch (e) {
      // ignore: avoid_print
      print('link: MLS store init failed: $e — retrying post-link');
    }

    final challenge = await _api.requestChallenge(
      username: username,
      deviceId: deviceId,
    );
    final signature =
        await _crypto.signWithIdentity(identity, challenge.challenge);
    final issued = await _api.submitSession(
      username: username,
      deviceId: deviceId,
      challenge: challenge.challenge,
      signature: signature,
    );

    // The session POST returns only {jwt}; stamp the identity fields the
    // pending lookup gave us so the session is fully populated.
    final session = JwtSession(
      accountId: accountId,
      deviceId: deviceId,
      jwt: issued.jwt,
      username: username,
    );
    await _sessions.save(session);

    // Best-effort: register MLS + seed our own KeyPackage pool so peers can
    // invite this device to groups. A failure leaves MLS unavailable until the
    // next foreground replenishment but must not fail the link.
    try {
      // Idempotent once open; the retry for a store that failed above.
      await _crypto.mlsInit();
      await _crypto.mlsEnsureClient(session.deviceId);
      final kps = await _crypto.mintKeyPackages(count: 100);
      _api.setBearerToken(session.jwt);
      await _api.publishKeyPackages(kps);
    } catch (_) {
      // Swallowed — see above.
    }
    return session;
  }

  static String _hex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}
