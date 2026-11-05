/// Whether, and over which route, this device fetches a linked page to build a
/// preview card for a message the user sends.
///
/// Previews are built on the SENDER's device and sent to the recipient inside the
/// encrypted message, so the recipient never contacts the site. What the site (or
/// its network) can learn is limited to the sender's fetch.
enum LinkPreviewMode {
  /// Never fetch; links are sent as plain text.
  off,

  /// Fetch only through Tor (the in-app Tor or the user's own SOCKS proxy), so
  /// the site never sees the sender's IP. With no Tor route available, no preview
  /// is made. The default.
  viaTor,

  /// Also fetch directly when Tor is off. The linked site sees the sender's IP.
  always;

  static LinkPreviewMode fromName(String? name) {
    return LinkPreviewMode.values.firstWhere(
      (m) => m.name == name,
      orElse: () => LinkPreviewMode.viaTor,
    );
  }
}
