# logos_sdk — Nim SDK for Logos modules

A standalone Nim package (`logos_sdk`) mirroring `logos-rust-sdk`: the lp_* runtime
+ a LIDL→Nim generator. See `README.md` for the full design. Originally extracted
and generalized from the [muster](https://github.com/corpetty/muster) project (its
first consumer).

## Rules
- **Pure logic stays FFI-free.** `bytes.nim` and `lidl-gen/gen.nim` must not import
  `ffi.nim` — they are the headlessly-testable core (`nim r`). The FFI/proxy/context
  modules resolve `lp_*` only at plugin link time.
- **The `{"_bytes":<b64url unpadded>}` form is shared with logos-rust-sdk** — change
  `bytes.nim` only in lockstep with `src/bytes.rs`; the vectors in `tests/tbytes.nim`
  pin cross-SDK interop.
- **`accept_token` must call `saveToken`.** The generated provider surface's
  `logos_module_accept_token` delegates to `api.saveToken`; dropping it silently
  breaks every outbound call (muster's cross-host regression — do not regress it).
- **Author procs are module-stem-prefixed** (`musterHealth`, not `health`) so a
  method name can't collide with a system/imported identifier. Keep the prefix.
- Every change runs `nimble test` (tbytes + tgen) green before commit.
