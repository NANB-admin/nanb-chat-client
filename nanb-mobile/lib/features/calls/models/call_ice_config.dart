/// ICE configuration handed to the call media engine. Defaults to **relay-only**
/// — the privacy posture from `docs/voice-calls-design.md`: with no host/srflx
/// candidates, peers never learn each other's IP and all media transits NANb's
/// own TURN as encrypted SRTP. [iceServers] is `[{urls, username, credential}]`
/// (short-lived TURN credentials from the server's cred endpoint). For a local
/// smoke test you can pass `relayOnly: false` with a STUN server to allow host
/// candidates.
class CallIceConfig {
  const CallIceConfig({this.iceServers = const [], this.relayOnly = true});
  final List<Map<String, dynamic>> iceServers;
  final bool relayOnly;
}
