import 'package:dio/dio.dart';
import 'package:dio/io.dart';

import 'socks_proxy.dart';
import '../models/account.dart';
import '../models/turn_credentials.dart';
import '../models/api_error.dart';
import '../models/device.dart';
import '../models/envelope.dart';
import '../models/json_bytes.dart';
import '../models/jwt_session.dart';
import '../models/report_request.dart';
import '../secure_storage/secure_storage.dart';
import '../secure_storage/secure_storage_impl.dart';
import 'api_client.dart';

/// Production Dio-backed API client. Excluded from coverage — exercised
/// indirectly via integration during manual ad-hoc testing.
///
/// **Timeouts:** the default Dio config has none, which lets a hung server
/// freeze the UI for hours. We set sane base limits here; the bytes-to-URL
/// methods (which exchange large media blobs) override with longer values.
class ApiClientDio implements ApiClient {
  /// [socksProxy], when set, tunnels every request through a local SOCKS5
  /// proxy (Tor). Ignored when a [dio] is injected directly (tests supply
  /// their own adapter). See `core/network/socks_proxy.dart`.
  ApiClientDio({
    required String baseUrl,
    Dio? dio,
    SocksProxyConfig? socksProxy,
    // Tests that inject [dio] directly can force the Tor branch (the SOCKS
    // routing is applied by [dio], not visible to us). Defaults to whether a
    // [socksProxy] was given for the production constructor.
    bool? onTor,
  })  : _dio = dio ?? _buildDio(baseUrl, socksProxy),
        _onTor = onTor ?? (socksProxy != null);

  static Dio _buildDio(String baseUrl, SocksProxyConfig? socksProxy) {
    final dio = Dio(BaseOptions(
      baseUrl: baseUrl,
      connectTimeout: const Duration(seconds: 10),
      sendTimeout: const Duration(seconds: 30),
      receiveTimeout: const Duration(seconds: 30),
    ));
    if (socksProxy != null) {
      // Route every connection (including the presigned-S3 media hosts) through
      // the proxy. createHttpClient is called once and the adapter caches it.
      dio.httpClientAdapter = IOHttpClientAdapter(
        createHttpClient: () => buildHttpClient(socksProxy),
      );
    }
    return dio;
  }

  /// Constructs an authed [ApiClientDio] from raw SecureStorage state,
  /// suitable for a background isolate that lacks Riverpod.
  ///
  /// Reads the JWT under key `session.jwt` and the server URL under
  /// `pref.server_url` (defaulting to `https://nanb.link`, matching
  /// `AppPreferences` default). Throws [StateError] when no JWT is
  /// stored — the FCM bg handler catches and falls through to opaque.
  ///
  /// Fail-closed under built-in Tor: this path has no Tor engine to route
  /// through (the embedded engine runs only in the foreground, and an FCM
  /// wakeup means the live socket is down — the app is typically
  /// suspended/killed, so the engine is not running). A clearnet call here
  /// would leak this device's real IP ↔ account to the server, defeating the
  /// anonymity the user opted into. So when Tor is enabled we throw instead of
  /// building a clearnet client; the delivered receipt + push preview are
  /// deferred to the foreground (which runs over Tor). Callers catch this and
  /// fall through to a generic wake notification. Tor is opt-in and defaults
  /// OFF, so only an explicit `true` (the user turned Tor ON) blocks the
  /// clearnet background path; absent/`false` permits it.
  static Future<ApiClientDio> createForBackgroundIsolate({
    SecureStorage? storage,
  }) async {
    final secure = storage ?? SecureStorageImpl();
    final torOn =
        (await secure.getString('pref.built_in_tor_enabled')) == 'true';
    if (torOn) {
      throw StateError('built-in Tor enabled: background isolate must not '
          'use clearnet (receipt/preview deferred to the foreground over Tor)');
    }
    final jwt = await secure.getString('session.jwt');
    if (jwt == null) {
      throw StateError('no JWT in SecureStorage; background isolate cannot auth');
    }
    final baseUrl = await secure.getString('pref.server_url')
        ?? 'https://nanb.link';
    final client = ApiClientDio(baseUrl: baseUrl);
    client.setBearerToken(jwt);
    return client;
  }

  /// Larger window for media uploads — at the 100 MB cap and a slow mobile
  /// uplink (~3 Mbps), we'd otherwise time out mid-PUT.
  static const Duration _mediaSendTimeout = Duration(minutes: 5);
  static const Duration _mediaReceiveTimeout = Duration(minutes: 2);

  final Dio _dio;

  /// Connect budget for the unauthenticated sealed deposit off Tor (see
  /// [submitSealedUnauthenticated]).
  static const Duration unauthConnectTimeout = Duration(seconds: 3);
  String? _jwt;

  /// True when this client routes over built-in Tor (a SOCKS proxy was
  /// configured). Media fetches then go through the server's onion stream
  /// endpoint instead of a presigned CDN/S3 URL, so media bytes don't egress
  /// via a Tor exit node. See [getMediaBytes].
  final bool _onTor;

  /// Releases the underlying Dio and its (possibly SOCKS-patched) HttpClient
  /// connection pool. Called from `apiClientProvider.onDispose` so rebuilding
  /// the client on a Network-settings Save doesn't leak the old one.
  void close() => _dio.close(force: true);

  @override
  void setBearerToken(String? jwt) {
    _jwt = jwt;
  }

  /// Bearer header for an authenticated request.
  ///
  /// Throws a **transient** [ApiError] (deliberately no `statusCode`) when no
  /// bearer is set, rather than sending the request anonymously. Sending it
  /// unauthenticated earns a guaranteed 401 — and a 401 *has* a status code, so
  /// every transience check in the app reads it as a PERMANENT client error and
  /// gives up. An outbox message that hits this window is then marked failed
  /// forever (`conversations_notifier`'s `_markOutboxFailed`) and only a manual
  /// tap re-sends it.
  ///
  /// The window is real, not theoretical: when built-in Tor finishes
  /// bootstrapping, its SOCKS port changes, which cascades through
  /// `socksProxyProvider` → `apiClientProvider` and yields a FRESH client whose
  /// bearer hasn't been re-set yet — `connect()` restores it a moment later. So
  /// "no bearer yet" is a temporary lifecycle gap, and reporting it as transient
  /// lets the caller's retry ride it out instead of destroying the message.
  Map<String, dynamic> get _authHeaders {
    final jwt = _jwt;
    if (jwt == null) {
      throw const ApiError(
        code: 'no_session',
        message: 'no bearer token on this client yet',
      );
    }
    return {'Authorization': 'Bearer $jwt'};
  }

  @override
  Future<JwtSession> createAccount(CreateAccountPayload payload) async {
    final r = await _post('/accounts', payload.toJson());
    return JwtSession.fromJson({...r, 'username': payload.username});
  }

  @override
  Future<UsernameAvailability> checkUsername(String username) async {
    try {
      final response = await _dio.get<dynamic>('/usernames/$username');
      return UsernameAvailability.fromJson(
          Map<String, dynamic>.from(response.data as Map));
    } on DioException catch (e) {
      throw _toApiError(e);
    }
  }

  @override
  Future<Account> lookupAccount(String username) async {
    try {
      final response = await _dio.get<dynamic>(
        '/accounts/$username',
        options: Options(headers: _authHeaders),
      );
      return Account.fromJson(Map<String, dynamic>.from(response.data as Map));
    } on DioException catch (e) {
      throw _toApiError(e);
    }
  }

  @override
  Future<Account> lookupAccountByDevice(String deviceId) async {
    try {
      final response = await _dio.get<dynamic>(
        '/devices/$deviceId/account',
        options: Options(headers: _authHeaders),
      );
      return Account.fromJson(Map<String, dynamic>.from(response.data as Map));
    } on DioException catch (e) {
      throw _toApiError(e);
    }
  }

  @override
  Future<Account> lookupAccountById(String accountId) async {
    try {
      final response = await _dio.get<dynamic>(
        '/accounts/by-id/$accountId',
        options: Options(headers: _authHeaders),
      );
      return Account.fromJson(Map<String, dynamic>.from(response.data as Map));
    } on DioException catch (e) {
      throw _toApiError(e);
    }
  }

  @override
  Future<List<Device>> listDevices() async {
    try {
      final response = await _dio.get<dynamic>(
        '/devices',
        options: Options(headers: _authHeaders),
      );
      final body = Map<String, dynamic>.from(response.data as Map);
      final list = body['devices'] as List? ?? const [];
      return list
          .cast<Map<String, dynamic>>()
          .map(Device.fromJson)
          .toList(growable: false);
    } on DioException catch (e) {
      throw _toApiError(e);
    }
  }

  @override
  Future<void> reportSealedCapability(
      {List<int> x25519PubKey = const []}) async {
    try {
      await _dio.post<dynamic>(
        '/devices/me/capabilities',
        data: x25519PubKey.isEmpty
            ? null
            : <String, dynamic>{'x25519_pub_key': x25519PubKey},
        options: Options(headers: _authHeaders),
      );
    } on DioException catch (e) {
      throw _toApiError(e);
    }
  }

  @override
  Future<void> updateProfile({String? displayName, String? avatarUrl}) async {
    try {
      await _dio.patch<dynamic>(
        '/accounts/me',
        data: {
          'display_name': ?displayName,
          'avatar_url': ?avatarUrl,
        },
        options: Options(headers: _authHeaders),
      );
    } on DioException catch (e) {
      throw _toApiError(e);
    }
  }

  @override
  Future<LinkDeviceResult> linkDevice(LinkDevicePayload payload) async {
    final r = await _post('/devices/link', payload.toJson(), authed: true);
    return LinkDeviceResult(
      deviceId: r['device_id'] as String,
      linkedAt: (r['linked_at'] as String?) ?? '',
    );
  }

  @override
  Future<PendingDevice> getPendingDevice(String devicePubKeyHex) async {
    try {
      final response = await _dio.get<dynamic>('/devices/pending/$devicePubKeyHex');
      return PendingDevice.fromJson(
          Map<String, dynamic>.from(response.data as Map));
    } on DioException catch (e) {
      throw _toApiError(e);
    }
  }

  @override
  Future<ChallengeReply> requestChallenge({
    required String username,
    required String deviceId,
  }) async {
    final r = await _post('/sessions/challenge', {
      'username': username,
      'device_id': deviceId,
    });
    return ChallengeReply(
      challenge: bytesFromJson(r['challenge']),
      expiresAt: DateTime.fromMillisecondsSinceEpoch(
        (r['expires_at'] as int) * 1000,
        isUtc: true,
      ),
    );
  }

  @override
  Future<JwtSession> submitSession({
    required String username,
    required String deviceId,
    required List<int> challenge,
    required List<int> signature,
  }) async {
    final r = await _post('/sessions', {
      'username': username,
      'device_id': deviceId,
      'challenge': challenge,
      'signature': signature,
    });
    // The server's SessionResponse carries ONLY {jwt} — account/device
    // identity don't change on refresh, so fill them from the request
    // context. (JwtSession.fromJson on the raw reply null-cast-crashed,
    // which silently broke every session refresh until a JWT first aged
    // past 24h.)
    return JwtSession(
      accountId: (r['account_id'] as String?) ?? '',
      deviceId: (r['device_id'] as String?) ?? deviceId,
      jwt: r['jwt'] as String,
      username: username,
    );
  }

  @override
  Future<ChallengeReply> requestRestoreChallenge({required String username}) async {
    final r = await _post('/sessions/restore/challenge', {
      'username': username,
    });
    return ChallengeReply(
      challenge: bytesFromJson(r['challenge']),
      expiresAt: DateTime.fromMillisecondsSinceEpoch(
        (r['expires_at'] as int) * 1000,
        isUtc: true,
      ),
    );
  }

  @override
  Future<JwtSession> submitRestoreSession({
    required String username,
    required List<int> identityPubKey,
    required List<int> challenge,
    required List<int> signature,
    List<int> devicePubKey = const [],
    List<int> x25519PubKey = const [],
  }) async {
    final r = await _post('/sessions/restore', {
      'username': username,
      'identity_pub_key': identityPubKey,
      'challenge': challenge,
      'signature': signature,
      if (devicePubKey.isNotEmpty) 'device_pub_key': devicePubKey,
      if (x25519PubKey.isNotEmpty) 'x25519_pub_key': x25519PubKey,
    });
    return JwtSession.fromJson({...r, 'username': username});
  }

  @override
  Future<SubmitMessageResult> submitMessage(SubmitMessagePayload payload) async {
    final r = await _post('/messages', payload.toJson(), authed: true);
    return SubmitMessageResult(
      envelopeId: r['envelope_id'] as String,
      serverTs: DateTime.parse(r['server_ts'] as String),
    );
  }

  @override
  Future<SubmitMessageResult> submitSealedUnauthenticated(
      SubmitMessagePayload payload, List<int> accessKey) async {
    // UNAUTHENTICATED: no bearer token, so the server never sees the sender.
    // access_key rides the same way ciphertext does (a byte array the Go
    // decoder accepts as []byte). A non-2xx (403/429) throws via _post.
    final body = payload.toJson()..['access_key'] = accessKey;
    // A SHORT connect budget off Tor. This deposit is an optional privacy
    // upgrade with an authed fallback, yet it ran first on every sealed send,
    // so a fresh connection that stalled (the idle keep-alive had dropped) held
    // the real send for the full 10s connect timeout — measured on-device
    // 2026-10-21 as a 10s-late call ring. A connect timeout means the request
    // never reached the server, so falling back cannot double-deposit. Tor
    // keeps the default: SOCKS + circuit setup legitimately takes longer.
    final r = await _post('/messages/sealed', body,
        authed: false, connectTimeout: _onTor ? null : unauthConnectTimeout);
    return SubmitMessageResult(
      envelopeId: r['envelope_id'] as String,
      serverTs: DateTime.parse(r['server_ts'] as String),
    );
  }

  @override
  Future<void> reportAccessKeyCommitment(List<int> commitment) async {
    try {
      // 204 No Content — use _dio.post directly (not _post, which parses a body).
      await _dio.post<dynamic>(
        '/accounts/me/access-key',
        data: {'commitment': commitment},
        options: Options(headers: _authHeaders),
      );
    } on DioException catch (e) {
      throw _toApiError(e);
    }
  }

  @override
  Future<List<Envelope>> catchupMessages({DateTime? since, int? limit}) async {
    final r = await _post('/messages/catchup', {
      'since_server_ts': ?since?.toUtc().toIso8601String(),
      'limit': ?limit,
    }, authed: true);
    final list = r['envelopes'] as List? ?? const [];
    return list
        .cast<Map<String, dynamic>>()
        .map(Envelope.fromJson)
        .toList(growable: false);
  }

  @override
  Future<int> ackMessages(List<String> envelopeIds) async {
    final r = await _post('/messages/ack', {
      'envelope_ids': envelopeIds,
    }, authed: true);
    return r['acked_count'] as int;
  }

  /// Transport-level "delivered" beacon: confirms to the server that this
  /// device physically received the pushed envelope (the FCM wakeup landed),
  /// WITHOUT decrypting or acking it. The server relays a delivery receipt to
  /// the original sender so their UI can show a double-check before the app is
  /// opened. Deliberately NOT on the [ApiClient] interface — only the
  /// background isolate (built via [createForBackgroundIsolate]) calls it; the
  /// foreground earns "delivered" via the peer's end-to-end receipt instead.
  Future<void> confirmReceived(String envelopeId) async {
    await _post('/messages/received', {'envelope_id': envelopeId}, authed: true);
  }

  @override
  Future<MediaUploadInit> initMediaUpload({
    required List<int> sha256,
    required int sizeBytes,
    required String mimeType,
    int? ttlSeconds,
    List<String>? authorizedAccountIds,
  }) async {
    final r = await _post('/media/init', {
      'sha256': sha256,
      'size_bytes': sizeBytes,
      'mime_type': mimeType,
      'ttl_seconds': ?ttlSeconds,
      // Omit when empty → server keeps legacy open access.
      if (authorizedAccountIds != null && authorizedAccountIds.isNotEmpty)
        'authorized_account_ids': authorizedAccountIds,
    }, authed: true);
    return MediaUploadInit(
      mediaId: r['media_id'] as String,
      uploadUrl: r['upload_url'] as String,
      uploadExpiry: DateTime.parse(r['upload_expiry'] as String),
    );
  }

  /// Relative path marker for the server's onion media-stream endpoint. A real
  /// download URL is always an absolute `https://…` (presigned S3/CloudFront);
  /// a value starting with `/` means "fetch from our own server" — which on
  /// Tor [getBytesFromUrl] routes through the proxied Dio (onion baseUrl) with
  /// the bearer token, so media bytes don't egress via a Tor exit node.
  static const _streamPath = '/media/stream';

  @override
  Future<MediaDownload> getMedia(String mediaId) async {
    if (_onTor) {
      // On Tor: skip the presigned-URL round trip entirely. Hand back a
      // pointer at our own onion stream endpoint; the server reads the object
      // from S3 inside AWS and streams the (already-E2EE) bytes back over the
      // onion. mimeType/sizeBytes are not needed by the download pipeline
      // (it verifies the plaintext sha from the descriptor), so leave them
      // empty/zero.
      return MediaDownload(
        downloadUrl: '$_streamPath?media_id=${Uri.encodeQueryComponent(mediaId)}',
        downloadExpiry: DateTime.now().toUtc().add(_mediaReceiveTimeout),
        mimeType: '',
        sizeBytes: 0,
      );
    }
    final r = await _post('/media/get', {'media_id': mediaId}, authed: true);
    return MediaDownload(
      downloadUrl: r['download_url'] as String,
      downloadExpiry: DateTime.parse(r['download_expiry'] as String),
      mimeType: r['mime_type'] as String,
      sizeBytes: r['size_bytes'] as int,
    );
  }

  @override
  Future<void> putBytesToUrl({
    required String url,
    required List<int> bytes,
    required String mimeType,
  }) async {
    try {
      await _dio.put<dynamic>(
        url,
        // MUST be a Stream: dio's request transformer stringifies a plain
        // List body ("[18, 52, ...]" — ~4.6x the size), which uploaded
        // garbled text to S3 and made every media download fail its
        // AES-GCM MAC check on the recipient. Streams bypass the
        // transformer and ship raw bytes.
        data: Stream<List<int>>.fromIterable(<List<int>>[bytes]),
        options: Options(
          headers: {
            'Content-Type': mimeType,
            // Streams carry no implicit length; S3 requires it.
            Headers.contentLengthHeader: bytes.length,
          },
          // The server doesn't expect a JSON response, and the presigned
          // URL is its own host — bypass the dio baseUrl.
          contentType: mimeType,
          sendTimeout: _mediaSendTimeout,
          receiveTimeout: _mediaReceiveTimeout,
        ),
      );
    } on DioException catch (e) {
      throw _toApiError(e);
    }
  }

  @override
  Future<List<int>> getBytesFromUrl(String url) async {
    // A relative path (our onion stream endpoint) resolves against the Dio
    // baseUrl (the onion host) and is authed; an absolute presigned S3/
    // CloudFront URL carries its own auth and needs no bearer token.
    final isOwnStream = url.startsWith(_streamPath);
    try {
      final response = await _dio.get<List<int>>(
        url,
        options: Options(
          headers: isOwnStream ? _authHeaders : null,
          responseType: ResponseType.bytes,
          receiveTimeout: _mediaReceiveTimeout,
        ),
      );
      return List<int>.from(response.data ?? const <int>[]);
    } on DioException catch (e) {
      throw _toApiError(e);
    }
  }

  @override
  Future<void> registerPushToken({
    required String platform,
    required String token,
  }) async {
    await _post('/devices/push-token', {
      'platform': platform,
      'token': token,
    }, authed: true);
  }

  @override
  Future<void> deletePushToken() async {
    try {
      await _dio.delete<dynamic>(
        '/devices/push-token',
        options: Options(headers: _authHeaders),
      );
    } on DioException catch (e) {
      throw _toApiError(e);
    }
  }

  @override
  Future<void> deleteAccount() async {
    try {
      await _dio.delete<dynamic>(
        '/accounts/me',
        options: Options(headers: _authHeaders),
      );
    } on DioException catch (e) {
      throw _toApiError(e);
    }
  }

  @override
  Future<void> reportUser(ReportRequest request) async {
    // _post throws _toApiError on a non-2xx; the 201 body ({ok, report_id}) is
    // parsed and discarded — the caller only needs success/failure.
    await _post('/reports', request.toJson(), authed: true);
  }

  @override
  Future<void> revokeDevice(String deviceId) async {
    try {
      await _dio.delete<dynamic>(
        '/devices/$deviceId',
        options: Options(headers: _authHeaders),
      );
    } on DioException catch (e) {
      throw _toApiError(e);
    }
  }

  // ─── KeyPackage endpoints ──────────────────────────────────────────────────

  @override
  Future<int> publishKeyPackages(
    List<List<int>> packages, {
    bool reset = false,
  }) async {
    // Go's [][]byte JSON-marshals as base64 strings automatically.
    // Dio serialises List<List<int>> as a JSON array of arrays (integers),
    // which matches what the server expects for [][]byte via encoding/json.
    // `reset` is omitempty server-side, so an ordinary top-up sends no flag
    // and behaves exactly as before against any server build.
    final r = await _post(
      '/accounts/me/key-packages',
      {'key_packages': packages, if (reset) 'reset': true},
      authed: true,
    );
    return r['stored_count'] as int;
  }

  @override
  Future<FetchKeyPackageResult> lookupKeyPackage(String username) async {
    try {
      final response = await _dio.get<dynamic>(
        '/accounts/$username/key-package',
        options: Options(headers: _authHeaders),
      );
      final body = Map<String, dynamic>.from(response.data as Map);
      return FetchKeyPackageResult(
        keyPackage: bytesFromJson(body['key_package']),
        replenishNeeded: body['replenish_needed'] as bool,
        remainingForUser: body['remaining_for_user'] as int,
      );
    } on DioException catch (e) {
      throw _toApiError(e);
    }
  }

  @override
  Future<List<DeviceKeyPackageResult>> lookupDeviceKeyPackages(
      String username) async {
    try {
      final response = await _dio.get<dynamic>(
        '/accounts/$username/key-packages',
        options: Options(headers: _authHeaders),
      );
      final body = Map<String, dynamic>.from(response.data as Map);
      final devices = (body['devices'] as List?) ?? const [];
      return [
        for (final d in devices)
          DeviceKeyPackageResult(
            deviceId: (d as Map)['device_id'] as String,
            keyPackage: bytesFromJson(d['key_package']),
          ),
      ];
    } on DioException catch (e) {
      throw _toApiError(e);
    }
  }

  @override
  Future<int> keyPackageCount() async {
    try {
      final response = await _dio.get<dynamic>(
        '/accounts/me/key-packages/count',
        options: Options(headers: _authHeaders),
      );
      final body = Map<String, dynamic>.from(response.data as Map);
      return body['count'] as int;
    } on DioException catch (e) {
      throw _toApiError(e);
    }
  }

  @override
  Future<Envelope> getEnvelopeById(String envelopeId) async {
    try {
      final response = await _dio.get<dynamic>(
        '/messages/by-id/$envelopeId',
        options: Options(headers: _authHeaders),
      );
      return Envelope.fromJson(Map<String, dynamic>.from(response.data as Map));
    } on DioException catch (e) {
      throw _toApiError(e);
    }
  }

  @override
  Future<TurnCredentials> fetchTurnCredentials() async {
    try {
      final response = await _dio.get<dynamic>(
        '/turn/credentials',
        options: Options(headers: _authHeaders),
      );
      return TurnCredentials.fromJson(
          Map<String, dynamic>.from(response.data as Map));
    } on DioException catch (e) {
      throw _toApiError(e);
    }
  }

  Future<Map<String, dynamic>> _post(
    String path,
    Map<String, dynamic> body, {
    bool authed = false,
    Duration? connectTimeout,
  }) async {
    try {
      final r = await _dio.post<dynamic>(
        path,
        data: body,
        options: Options(
          headers: authed ? _authHeaders : const {},
          connectTimeout: connectTimeout,
        ),
      );
      return Map<String, dynamic>.from(r.data as Map);
    } on DioException catch (e) {
      throw _toApiError(e);
    }
  }

  ApiError _toApiError(DioException e) {
    final response = e.response;
    if (response != null && response.data is Map) {
      return ApiError.fromJson(
        Map<String, dynamic>.from(response.data as Map),
        statusCode: response.statusCode,
      );
    }
    return ApiError(
      code: 'network',
      message: e.message ?? e.toString(),
      statusCode: response?.statusCode,
    );
  }
}
