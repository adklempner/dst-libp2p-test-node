# Recovered mix cbind sources

Full pre-deletion snapshots of every file the mix-extraction commit touched in
nim-libp2p's C bindings. Source of truth for the resurrection work in
`../PLAN.md` Phase 1.

- **Removed by**: `vacp2p/nim-libp2p@7e72c0d6` — "chore: extract mix to
  logos-co/nim-libp2p-mix (#2378)", 2026-05-07.
- **Snapshot taken at**: `7e72c0d6^` = `220a07fd` (see `SOURCE_COMMIT.txt`).
- **Originally added by**: `41acee2e` "feat(cbind): mix (#2064)" +
  `b143084b` "feat(cbind): mix follow up (#2087)".

These are FULL files, not just the mix hunks — diff against the current
`cbind/` in vacp2p/nim-libp2p master to isolate the mix-specific parts:

```bash
git -C <nim-libp2p> diff 7e72c0d6^ 7e72c0d6 -- cbind/   # exact deletions
```

| File | Mix-relevant content |
|---|---|
| `libp2p.h` | `libp2p_curve25519_key_t`, `libp2p_secp256k1_pubkey_t`, `mount_mix` config flag, `Libp2pMixReadBehavior` enum, 7 `libp2p_mix_*` function decls (lines ~521-555) |
| `libp2p.nim` | C-exported `libp2p_mix_*` procs marshaling onto the libp2p thread |
| `libp2p_lifecycle_requests.nim` | `mountMix` (lines ~207-213) — `MixProtocol.new(mixNodeInfo, switch)`, no spam protection |
| `libp2p_stream_requests.nim` | Thread-side MixDial / MixDialWithReply / read-behavior / nodepool handlers |
| `libp2p_thread_request.nim` | Request union dispatch incl. mix request types |
| `ffi_types.nim`, `types.nim` | FFI type plumbing |
| `mix.c` | 339-line working C example — reuse as smoke test |

Import-path delta for the port: `libp2p/protocols/mix/...` →
`libp2p_mix/...` (the extracted package).
