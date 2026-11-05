// Maps CoreCrypto (WASM) errors onto the same channel codes the Kotlin shim
// produces (see nanb_crypto/.../MlsExceptions.kt and
// lib/core/crypto/mls_exceptions.dart). The code travels to Dart inside the
// rejected Error's message as `nanb_mls_code=<code>;<message>` so the Dart side
// can recover it from any JS-error wrapper with a regex.
import { ErrorType, MlsErrorType, isCcError } from "@wireapp/core-crypto/src/corecrypto.js";

export class NanbMlsArgumentError extends Error {}

const DECRYPT_FAILED = new Set([
  MlsErrorType.DuplicateMessage,
  MlsErrorType.WrongEpoch,
  MlsErrorType.StaleCommit,
  MlsErrorType.MessageEpochTooOld,
  MlsErrorType.SelfCommitIgnored,
  MlsErrorType.MessageRejected,
]);
const INVALID_ARGUMENT = new Set([MlsErrorType.ConversationAlreadyExists, MlsErrorType.OrphanWelcome]);

function looksLikeMissingConversation(text) {
  const lower = String(text).toLowerCase();
  return lower.includes("not found") || lower.includes("find conversation") || lower.includes("unknown conversation");
}

export function classify(e) {
  const message = e && e.message ? String(e.message) : String(e);
  if (e instanceof NanbMlsArgumentError) return ["mls_invalid_argument", message];
  if (isCcError(e, ErrorType.Mls)) {
    const t = e.context && e.context.type;
    if (DECRYPT_FAILED.has(t)) return ["mls_decrypt_failed", message];
    if (INVALID_ARGUMENT.has(t)) return ["mls_invalid_argument", message];
    const detail = e.context && e.context.context && e.context.context.msg ? e.context.context.msg : message;
    if (looksLikeMissingConversation(detail) || looksLikeMissingConversation(message)) return ["mls_unknown_group", detail];
    return ["mls_unknown", detail];
  }
  // A missing conversation can also surface outside the structured Mls variant.
  if (looksLikeMissingConversation(message)) return ["mls_unknown_group", message];
  return ["mls_io", message];
}

export function toNanbError(e) {
  if (e && e.nanbCode) return e;
  const [code, message] = classify(e);
  const out = new Error(`nanb_mls_code=${code};${message}`);
  out.nanbCode = code;
  return out;
}
