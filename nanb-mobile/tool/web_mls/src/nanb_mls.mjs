// Flat async API over @wireapp/core-crypto (WASM) for the Flutter web client.
// One function per CryptoBridgeNative MLS method; only strings, numbers,
// booleans, Uint8Array, arrays and plain objects cross the boundary.
// Semantics mirror nanb_crypto/android (NanbCryptoChannel.kt, MlsClientHolder.kt).
import * as CC from "@wireapp/core-crypto/src/corecrypto.js";
import { NanbMlsArgumentError, isConversationAlreadyExists, toNanbError } from "./errors.mjs";
import { createSerialQueue } from "./serial_queue.mjs";

const { CoreCrypto, ClientId, ConversationId, DatabaseKey, Ciphersuite, CredentialType, Welcome, initWasmModule } = CC;

// JS enum names use `Ed25519`, not `ED25519`.
const SUITE = Ciphersuite.MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519;
const DB_PREFIX = "nanb-mls-";
const enc = new TextEncoder();
const dec = new TextDecoder();
const serial = createSerialQueue();

let wasmReady = null;
let cc = null;
let dbName = null;
let storeKey = null;
let clientReady = false;
let storeWasReset = false;
let lastBundle = null;

const transport = {
  sendCommitBundle: async (bundle) => {
    lastBundle = bundle;
    return "success";
  },
  sendMessage: async () => "success",
  prepareForTransport: async () => {
    throw new Error("history sharing is not supported");
  },
};

const cid = (s) => new ConversationId(enc.encode(s));

function need(cond, msg) {
  if (!cond) throw new NanbMlsArgumentError(msg);
}
function needString(v, name) {
  need(typeof v === "string" && v.length > 0, `missing ${name}`);
}
function needBytes(v, name) {
  need(v instanceof Uint8Array && v.length > 0, `missing ${name}`);
}
function client() {
  if (!cc) throw new Error("nanbMls.open must be called first");
  return cc;
}

function ensureWasm() {
  if (!wasmReady) {
    const base = window.nanbMlsWasmBase || new URL(".", document.baseURI).href;
    wasmReady = initWasmModule(base).catch((e) => {
      wasmReady = null;
      throw e;
    });
  }
  return wasmReady;
}

async function openStore(name, key) {
  return CoreCrypto.deferredInit({ databaseName: name, key: new DatabaseKey(key) });
}

async function listDbNames() {
  if (typeof indexedDB.databases !== "function") return [];
  return (await indexedDB.databases()).map((d) => d.name).filter(Boolean);
}

function deleteDb(name) {
  return new Promise((resolve) => {
    const req = indexedDB.deleteDatabase(name);
    req.onsuccess = req.onerror = req.onblocked = () => resolve();
  });
}

// The store key is deterministic from the identity seed, so a store that the
// correct key cannot open belongs to another identity (or is corrupt).
function isUnreadableStore(e) {
  return /not a database|code 26|notadb|decrypt|cipher|invalid key|wrong key|aead/i.test(String((e && e.message) || e));
}

async function doOpen(name, key) {
  if (cc) return;
  await ensureWasm();
  let c;
  try {
    c = await openStore(name, key);
  } catch (e) {
    const existed = (await listDbNames()).includes(name);
    if (!existed || !isUnreadableStore(e)) throw e;
    await deleteDb(name);
    // Every KeyPackage published from the destroyed store is now dead.
    storeWasReset = true;
    c = await openStore(name, key);
  }
  await c.provideTransport(transport);
  cc = c;
  dbName = name;
  storeKey = key;
  clientReady = false;
}

// Safety net only. The Dart side names the IndexedDB after the seed, so a
// different identity never meets a foreign store (unlike the fixed native file
// path). CoreCrypto does not reject a wrong key at open; the first decrypt of
// stored data fails with `aead::Error`, which mlsInit only sometimes hits.
// Recovery mirrors the native holder: rebuild the store and flag the reset.
async function recoverUnreadableStore() {
  const name = dbName;
  const key = storeKey;
  await doClose();
  await deleteDb(name);
  storeWasReset = true;
  await doOpen(name, key);
}

async function doEnsureClient(clientId) {
  if (clientReady) return;
  const init = () => client().transaction((c) => c.mlsInit(new ClientId(enc.encode(clientId)), [SUITE], 100));
  try {
    await init();
  } catch (e) {
    if (!isUnreadableStore(e)) throw e;
    await recoverUnreadableStore();
    await init();
  }
  clientReady = true;
}

async function doClose() {
  const c = cc;
  cc = null;
  clientReady = false;
  if (c) {
    try {
      await c.close();
    } catch (_) {
      // already closed
    }
  }
}

async function doWipe() {
  const known = dbName;
  await doClose();
  dbName = null;
  const names = new Set((await listDbNames()).filter((n) => n.startsWith(DB_PREFIX)));
  if (known) names.add(known);
  for (const n of names) await deleteDb(n);
}

async function captureBundle(op) {
  lastBundle = null;
  await client().transaction(op);
  const bundle = lastBundle;
  lastBundle = null;
  if (!bundle) throw new Error("CommitBundle was not dispatched to the transport");
  return bundle;
}

async function addMembersImpl(groupId, kps) {
  needString(groupId, "groupId");
  need(Array.isArray(kps) && kps.length > 0, "peerKeyPackages must not be empty");
  kps.forEach((k) => needBytes(k, "peerKeyPackage"));
  const bundle = await captureBundle((c) => c.addClientsToConversation(cid(groupId), kps));
  need(bundle.welcome, "commit carried no Welcome");
  return { welcome: bundle.welcome.copyBytes(), commit: bundle.commit };
}

async function decryptRaw(groupId, ciphertext) {
  needString(groupId, "groupId");
  needBytes(ciphertext, "ciphertext");
  return client().transaction((c) => c.decryptMessage(cid(groupId), ciphertext));
}

const impl = {
  async open(name, key) {
    needString(name, "databaseName");
    need(key instanceof Uint8Array && key.length === 32, "store key must be 32 bytes");
    await doOpen(name, key);
  },
  async ensureClient(clientId) {
    needString(clientId, "clientId");
    await doEnsureClient(clientId);
  },
  async close() {
    await doClose();
  },
  async wipe() {
    await doWipe();
  },
  async consumeStoreReset() {
    const was = storeWasReset;
    storeWasReset = false;
    return was;
  },
  async mintKeyPackages(count) {
    const n = count === undefined ? 100 : count;
    need(Number.isInteger(n) && n >= 1 && n <= 500, `count out of range: ${n}`);
    const kps = await client().transaction((c) => c.clientKeypackages(SUITE, CredentialType.Basic, n));
    return kps.map((k) => new Uint8Array(k));
  },
  async createGroup(conversationId) {
    needString(conversationId, "conversationId");
    await client().transaction((c) => c.createConversation(cid(conversationId), CredentialType.Basic));
    return conversationId;
  },
  async addMember(groupId, keyPackage) {
    needBytes(keyPackage, "peerKeyPackage");
    return addMembersImpl(groupId, [keyPackage]);
  },
  addMembers: addMembersImpl,
  async removeMember(groupId, targetDeviceId) {
    needString(groupId, "groupId");
    needString(targetDeviceId, "targetDeviceId");
    const bundle = await captureBundle((c) =>
      c.removeClientsFromConversation(cid(groupId), [new ClientId(enc.encode(targetDeviceId))]),
    );
    return bundle.commit;
  },
  async processWelcome(welcome) {
    needBytes(welcome, "welcomeBytes");
    const wb = await client().transaction((c) => c.processWelcomeMessage(new Welcome(welcome)));
    return dec.decode(wb.id.copyBytes());
  },
  async processCommit(groupId, commit) {
    needBytes(commit, "commitBytes");
    await decryptRaw(groupId, commit);
  },
  async currentEpoch(groupId) {
    needString(groupId, "groupId");
    return client().conversationEpoch(cid(groupId));
  },
  async groupMembers(groupId) {
    needString(groupId, "groupId");
    const ids = await client().getClientIds(cid(groupId));
    return ids.map((id) => dec.decode(id.copyBytes()));
  },
  async encrypt(groupId, plaintext) {
    needString(groupId, "groupId");
    need(plaintext instanceof Uint8Array, "missing plaintext");
    const out = await client().transaction((c) => c.encryptMessage(cid(groupId), plaintext));
    return new Uint8Array(out);
  },
  async decryptAndInspect(groupId, ciphertext) {
    const d = await decryptRaw(groupId, ciphertext);
    const selfRemoved = !d.isActive;
    let newEpoch = null;
    if (!selfRemoved) {
      try {
        newEpoch = await client().conversationEpoch(cid(groupId));
      } catch (_) {
        newEpoch = null; // same as native: epoch null, selfRemoved stays isActive-derived
      }
    }
    return {
      plaintext: d.message ? new Uint8Array(d.message) : null,
      selfRemoved,
      newEpoch,
      senderClientId: d.senderClientId ? dec.decode(d.senderClientId.copyBytes()) : null,
    };
  },
  async replaceGroup(localGroupId, foreignWelcome) {
    needString(localGroupId, "localGroupId");
    needBytes(foreignWelcome, "foreignWelcome");
    // Open the Welcome FIRST; only "already exists" proves it's good enough to
    // wipe for (see NanbCryptoChannel.kt).
    try {
      return await impl.processWelcome(foreignWelcome);
    } catch (e) {
      if (!isConversationAlreadyExists(e)) throw e;
    }
    // Best-effort wipe in its OWN transaction.
    try {
      await client().transaction((c) => c.wipeConversation(cid(localGroupId)));
    } catch (_) {
      // no local group to replace
    }
    return impl.processWelcome(foreignWelcome);
  },
  async wipeGroup(groupId) {
    needString(groupId, "groupId");
    await client().transaction((c) => c.wipeConversation(cid(groupId)));
  },
};

const api = {};
for (const [name, fn] of Object.entries(impl)) {
  api[name] = (...args) =>
    serial(async () => {
      try {
        return await fn(...args);
      } catch (e) {
        throw toNanbError(e);
      }
    });
}

window.nanbMls = Object.freeze(api);
