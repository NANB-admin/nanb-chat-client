// Runs async tasks strictly one after another. Every CoreCrypto call (and the
// single captured-CommitBundle slot) goes through this, mirroring the
// per-process serialisation the native bridge gets from CoreCrypto's store.
export function createSerialQueue() {
  let tail = Promise.resolve();
  return (task) => {
    const run = tail.then(task, task);
    tail = run.catch(() => undefined);
    return run;
  };
}
