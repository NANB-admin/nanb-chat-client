/// An MLS bridge whose store is opened with the identity seed.
///
/// `CryptoBridgeComposite` reads the seed from the identity bridge and hands it
/// over through this surface (implemented by `CryptoBridgeWeb`; the native
/// bridge exposes the same two methods); the no-arg `mlsInit()` of such a
/// bridge is unsupported.
abstract interface class MlsSeededBridge {
  Future<void> mlsInitWithSeed(List<int> seed);
  Future<void> mlsInitReadOnlyWithSeed(List<int> seed);
}
