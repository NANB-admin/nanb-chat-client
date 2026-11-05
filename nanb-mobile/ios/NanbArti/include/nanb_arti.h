/* C-ABI surface of the embedded Arti (Rust Tor) static library
   (libnanb_arti.a, built by .github/workflows/arti-ios.yml).

   Backs ios/Runner/TorChannel.swift (iOS Tor engine), replacing C-tor. Arti has
   a clean lifecycle, so the resume path is just stop()+start() (no wedge). The
   Swift side POLLS bootstrap_pct / is_ready / socks_port (no callbacks from
   Rust). All functions are panic-safe (catch_unwind in Rust). */
#ifndef NANB_ARTI_H
#define NANB_ARTI_H

#include <stdbool.h>
#include <stdint.h>

/* Start the embedded Tor: build + bootstrap a TorClient and bind an in-process
   SOCKS5 proxy. Returns 0 if the start was accepted (bootstrap continues async —
   poll the status), negative on failure (see nanb_arti_last_error). No-op if
   already running. data_dir = a UTF-8 path (the app's Application Support dir);
   Arti state/cache live under <data_dir>/arti-state and /arti-cache. */
int32_t nanb_arti_start(const char *data_dir);

/* Cleanly stop the engine (cancel tasks, drop the client, release data-dir
   locks) so a subsequent start() — the resume restart — gets a clean slate. */
void nanb_arti_stop(void);

/* The live SOCKS5 port on 127.0.0.1, or 0 until the listener is bound. */
uint16_t nanb_arti_socks_port(void);

/* Bootstrap progress, 0..100. */
int32_t nanb_arti_bootstrap_pct(void);

/* True once bootstrapped AND the SOCKS listener is bound (i.e. routable). */
bool nanb_arti_is_ready(void);

/* Suspend (dormant = true) / resume (dormant = false) the client's background
   activity WITHOUT tearing it down — the client, its guards, and the SOCKS port
   all survive. Called on app pause/resume so a resume is a cheap wake instead of
   a full re-bootstrap. Arti also auto-wakes on first use. No-op until
   bootstrapped. */
void nanb_arti_set_dormant(bool dormant);

/* Last error message (NUL-terminated), or NULL if none. Valid until the next
   FFI call that records an error; copy it immediately. */
const char *nanb_arti_last_error(void);

#endif /* NANB_ARTI_H */
