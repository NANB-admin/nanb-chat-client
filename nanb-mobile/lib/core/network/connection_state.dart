/// Coarse-grained connection state surfaced to the UI by
/// `WsReconnectSupervisor` and re-exposed via `ConversationsNotifier`.
///
/// Drives the `ConnectionBanner` widget and the router's signedOut redirect.
enum ConnectionState {
  /// Initial state or post-backoff attempt in progress.
  connecting,

  /// WS open and delivering envelopes.
  connected,

  /// A drop has been observed; waiting on backoff or in-flight retry.
  reconnecting,

  /// JWT refresh failed permanently. Supervisor is terminal; router
  /// redirects to /welcome.
  signedOut,
}
