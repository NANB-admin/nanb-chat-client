/// Wire-protocol mode of a 1:1 conversation. New conversations land as
/// [ratchet]; on the next outbound message a successful soft migration
/// flips them to [mls]. Plan B implements that flip. Pre-Plan-B
/// conversations land + persist as [ratchet] by default.
enum CryptoMode {
  ratchet,
  mls;

  static CryptoMode fromName(String s) {
    switch (s) {
      case 'ratchet':
        return CryptoMode.ratchet;
      case 'mls':
        return CryptoMode.mls;
      default:
        throw ArgumentError('unknown crypto mode: $s');
    }
  }
}
