/// What sort of client a linked device is. Wire values are "phone" / "web".
enum DeviceKind {
  phone('phone'),
  web('web');

  const DeviceKind(this.wire);

  /// The string the server speaks.
  final String wire;

  /// Lenient parse: null, missing or unknown values are [phone] so an older
  /// server (or a newer one with a kind we don't know) keeps working.
  static DeviceKind fromWire(String? value) =>
      value == 'web' ? DeviceKind.web : DeviceKind.phone;
}
