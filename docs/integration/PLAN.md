# Plan: Standalone libp2p mix nodes in logos-core, with RLN-on-LEZ spam protection

Master plan for an agent to build this out iteratively. Each phase is
independently verifiable; do not start phase N+1 until phase N's acceptance
criteria pass. Keep a running `PROGRESS.md` next to this file: one entry per
work session with what changed, what passed, what's blocked.

## Goal

Take the standalone libp2p mix node (this repo, `nim-test-node/mix/`) and:

1. **Goal A** — run mix nodes as logos-core modules (logoscore daemon,
   `.lgx` packaging, `call`-driven lifecycle).
2. **Goal B** — give them RLN spam protection backed by LEZ (on-chain
   membership tree on the LSSA sequencer / testnet).

## Architecture decision (already made — do not relitigate)

We do NOT hand-FFI this repo's `main.nim`, and we do NOT clone the
logos-chat sim's hand-written Qt-plugin style. Instead:

- **`logos-libp2p-module`** (github:logos-co/logos-libp2p-module) is the
  vehicle. It already wraps nim-libp2p's `cbind` C library using the modern
  `interface: universal` pure-C++ pattern, and contains a complete-but-disabled
  mix wrapper (`src/mix.cpp`, `src/plugin.h:122-143` behind `#if 0`) plus an
  in-process 5-node mix integration test (`tests/integration_mix.cpp`).
  Comment on the `#if 0`: "mix temporarily disabled — extracted to separate
  repo, no cbindings yet".
- The missing piece is the **mix C bindings**, which were DELETED from
  nim-libp2p when mix was extracted to `logos-co/nim-libp2p-mix`
  (commit `7e72c0d6`, 2026-05-07). Full pre-deletion sources are preserved
  under `reference/recovered-cbind/` — this is a port, not a rewrite.
- **RLN stays out of nim-libp2p-mix.** The mix cbind gets ONE generic,
  RLN-agnostic injection hook (a spam-protection factory registry). All RLN
  C surface + librln linkage + the combined artifact live in
  `adklempner/mix-rln-spam-protection-plugin`.
- This repo (`dst-libp2p-test-node`) remains the scale-test harness
  (Docker/Shadow); the logos-core embodiment is the module. The two share
  the same Nim mix stack underneath.

```
nim-libp2p (cbind: switch/gossipsub/kad, thread+request infra)
   ▲ depends                           ▲ flake input "libp2p" (cbind output)
nim-libp2p-mix (mix + NEW resurrected mix cbind + generic SP factory hook)
   ▲ depends
mix-rln-spam-protection-plugin (RLN impl + NEW cbind-rln C surface
                                + NEW combined `cbind-rln` flake output, links librln)
   ▲ externalLibInputs.libp2p = #cbind-rln
logos-libp2p-module (re-enabled mix.cpp + NEW rln methods;
                     deps: wallet + rln logos modules via modules().*)
   ▲ .lgx
logoscore daemon  ←  orchestration / sims
```

## Repos & pins

| Repo | Role | Rev notes |
|---|---|---|
| `vacp2p/dst-libp2p-test-node` (this, `feat/mix`) | reference node + scale harness | mix test-node pins below |
| `vacp2p/nim-libp2p` | base + cbind infra | test node pins `c431993` (release/v2.0.0 tip); libp2p-module flake.lock pins `3f5a4dce`. Deleted mix cbind recoverable at `7e72c0d6^` |
| `logos-co/nim-libp2p-mix` | mix protocol (package `libp2p_mix`) | test node pins head `3805131` (2026-06-09). `MixProtocol.new` already takes `spamProtection: Opt[SpamProtection]` (mix_protocol.nim:1016,1097) |
| `adklempner/mix-rln-spam-protection-plugin` (canonical; no vacp2p repo exists) | RLN SpamProtection impl | main `b3e3f72`; pins `libp2p_mix` at `adklempner/nim-libp2p-mix#48b2e3b` + nim-libp2p `e1bbda4f6` — STALE, must move to current head |
| `logos-co/logos-libp2p-module` | the logos-core module | master `739f72c`; flake input `libp2p` w/ `packages.default = "cbind"` |
| `logos-co/logos-module-builder`, `logos-cpp-sdk`, `logos-logoscore-cli`, `logos-package-manager` | platform tooling | use `tutorial-v3` tags as known-good baseline |
| `logos-co/logos-lez-rln` (vendored in logos-chat) | LEZ programs, wallet module, rln module, sequencer | see local checkout `~/Waku/Logos/logos-chat/vendor/logos-lez-rln` |

Local reference checkouts (read-only context for the agent):
- `~/Waku/Logos/logos-chat` — the existing sim stack; stage-by-stage notes at
  `simulations/mix_lez_chat/SIMULATION_STAGES.md`.
- `/tmp/nim-libp2p` (full-history clone, blob-filtered), `/tmp/nim-libp2p-mix`,
  `/tmp/logos-libp2p-module`, `/tmp/logos-tutorial` — may need re-cloning if
  /tmp was cleared.

---

## Phase 0 — Workspace + baseline validation

**Goal**: every repo builds at its current pin before we change anything.

Tasks:
1. Clone working copies (fork branches, never push to upstream masters):
   `nim-libp2p-mix`, `mix-rln-spam-protection-plugin`, `logos-libp2p-module`.
2. Build `nim-libp2p-mix` tests (`nimble test` or its Makefile) at head.
3. Build `logos-libp2p-module` as-is: `nix build` and `nix build '.#unit-tests'`.
   Confirm the non-mix integration tests pass (gossipsub, kad).
4. Build this repo's mix node once (`Dockerfile_amd64_dev`) to have the
   reference behavior available.

Acceptance: all three builds green at unmodified pins. Record exact revs in
PROGRESS.md.

## Phase 1 — Resurrect the mix cbind inside nim-libp2p-mix

**Goal**: nim-libp2p-mix gains a `cbind` flake output producing
`libp2p.so` + `libp2p.h` that includes the 7 mix functions.

The recovered sources in `reference/recovered-cbind/` are the spec. The
module-side consumer (`logos-libp2p-module/src/mix.cpp`) expects EXACTLY:
`libp2p_mix_generate_priv_key`, `libp2p_mix_public_key`, `libp2p_mix_dial`,
`libp2p_mix_dial_with_reply`, `libp2p_mix_register_dest_read_behavior`,
`libp2p_mix_set_node_info`, `libp2p_mix_nodepool_add`,
`libp2p_curve25519_key_t`, `LIBP2P_MIX_READ_EXACTLY`.

Tasks:
1. **Structural decision (start here, keep it cheap):** copy nim-libp2p's
   current `cbind/` directory layout into nim-libp2p-mix as `cbind/`
   (vendor-the-shell approach). The mix cbind composes: base cbind modules
   (imported from the nim-libp2p dependency where importable; copied where
   the request union forces it) + the recovered mix request handlers.
   Document precisely which files are copies vs imports — this debt is
   intentional; upstreaming an extensible request union into nim-libp2p is a
   separate later track.
2. Port the recovered files:
   - import paths `libp2p/protocols/mix/...` → `libp2p_mix/...`
   - reconcile API drift vs current head (`MixProtocol.new` signature now has
     `spamProtection`/`delayStrategy`/`coverTraffic`; check `MixDestination`,
     `MixParameters`, `registerDestReadBehavior` shapes against
     `libp2p_mix/mix_protocol.nim`)
3. Add the **generic spam-protection factory hook** (RLN-agnostic, ~10 lines):
   ```nim
   var spamProtectionFactory: proc(): Opt[SpamProtection] {.gcsafe.} = nil
   proc registerSpamProtectionFactory*(f: ...) = spamProtectionFactory = f
   # mountMix: sp = if factory.isNil: Opt.none(...) else: factory()
   ```
   Mount-time-only injection. Do NOT add a post-construction setter —
   spam protection changes wire packet size
   (`maxWireSize = PacketSize + proofSize`, mix_protocol.nim:496); flipping it
   on a live protocol invites mid-flight inconsistency.
4. Nix: add `packages.cbind` to nim-libp2p-mix's flake (mirror
   `nim-libp2p/nix/cbind.nix`).
5. Port `reference/recovered-cbind/mix.c` to a smoke test: compile against the
   new header, run a 5-node in-process mix ping.

Acceptance:
- `nix build '.#cbind'` emits `libp2p.so`/`.h`; `nm` shows all 7
  `libp2p_mix_*` symbols.
- mix.c smoke test passes (mix dial + SURB reply round-trip).
- Non-mix cbind behavior unchanged (run nim-libp2p's cbind example against
  the new lib if feasible).

Risks: request-union merge conflicts with current nim-libp2p cbind (the
copied shell drifts from upstream); chronos/libp2p version skew between
nim-libp2p-mix's pin and the cbind shell's expectations. Resolve by pinning
the cbind shell to the SAME nim-libp2p rev nim-libp2p-mix depends on.

## Phase 2 — Re-enable mix in logos-libp2p-module

**Goal**: the `#if 0` block compiles, and `integration_mix.cpp` passes.

Tasks:
1. Point flake input: `libp2p.url = github:<fork>/nim-libp2p-mix/<branch>`,
   `externalLibInputs.libp2p.packages.default = "cbind"`.
2. Remove `#if 0`/`#endif` around the mix block in `src/plugin.h` (lines
   ~122-143) and any matching guard in `src/mix.cpp`.
3. Fix compile drift (StdLogosResult usage, callback signatures).
4. Re-enable `tests/integration_mix.cpp` in `tests/CMakeLists.txt` if gated.
5. Run `nix build '.#unit-tests' -L`.

Acceptance: `integration_mix.cpp` green — 5 in-process nodes, pubInfo
exchange via direct method calls, nodepool population, `mixDialWithReply`
ping with reply. Also verify via the daemon path:
`logoscore -D -m ./modules` + `lgpm install` of the `.lgx` + `logoscore call
libp2p_module ...` (tutorial Step 6 flow).

This completes **Goal A** in its minimal form: mix nodes runnable as
logos-core modules.

## Phase 3 — RLN C surface in mix-rln-spam-protection-plugin

**Goal**: plugin repo owns all RLN C bindings + a combined `cbind-rln`
artifact. No RLN content in nim-libp2p-mix.

Tasks:
1. Re-pin the plugin: `libp2p_mix` → the Phase-1 branch head;
   nim-libp2p → matching rev. Fix compile drift; run its existing tests
   (needs `librln.a` — see plugin nimble `LIBRLN_PATH`; reuse the librln-mix
   build from logos-delivery's targets).
2. New `src/mix_rln_spam_protection/cbind.nim` exporting (C, cdecl):
   - `libp2p_mix_rln_enable(config_json: cstring): cint` — parse config
     (rlnIdentifier, epochDurationSeconds, userMessageLimit, useOnchainLEZ,
     keystore path/password), construct `MixRlnSpamProtection`, call
     `registerSpamProtectionFactory`. MUST be called before `libp2p_new`;
     return error if the node already exists.
   - `libp2p_mix_rln_set_fetcher(fn, user_data): cint` — the trampoline.
     Port the proven pattern from
     `logos-chat/vendor/logos-delivery/logos_delivery/waku/waku_mix/logos_core_client.nim:173-205`
     (`callRlnFetcher`). C signature mirrors `logosdelivery_set_rln_fetcher`.
   - `libp2p_mix_rln_set_identity(id_secret_hash: ptr uint8, len: csize_t, leaf_index: int64): cint`
     — set credentials + membershipIndex on the group manager. Use
     **idSecretHash directly** (known pitfall: cpp/Nim seed→credential
     derivation mismatch between lez-rln and zerokit crates; never re-derive
     from seed).
   - `libp2p_mix_rln_is_ready(): cint` — surfaces
     `groupManager.isReady()` for host-side readiness gating.
   - `libp2p_mix_rln_start_polling(): cint` — wraps
     `OnchainLEZGroupManager.startPolling()` (call AFTER node start).
   - Ship `libp2p_mix_rln.h`.
3. Wire the LEZ callbacks internally: adapt
   `makeFetchLatestRoots`/`makeFetchMerkleProof` (same logos_core_client.nim,
   ~lines 360-393) into the plugin's cbind so `setFetchCallbacks` is called on
   the `OnchainLEZGroupManager` when `useOnchainLEZ` and a fetcher are present.
4. New flake output `cbind-rln`: compiles a main that imports
   `libp2p_mix cbind` + this cbind module, links librln. Emits
   `libp2p.so` (superset) + both headers.
5. Unit tests: fetcher trampoline round-trip with a stub C fetcher; enable →
   factory-registered; identity set → isReady transitions once a fake proof
   is pushed.

Acceptance: `nix build '.#cbind-rln'` green; `nm` shows `libp2p_mix_rln_*` +
all Phase-1 symbols; unit tests pass with a mocked fetcher.

Gotchas to encode in code comments/tests:
- The chronos loop lives on the cbind's dedicated libp2p thread; the fetcher
  callback will be invoked FROM that thread and typically calls back into the
  host (C++ → QtRO → other modules). It must be allowed to block that thread
  only briefly — prefer the host doing async internally. Never call the
  fetcher from a different thread than it was registered for without
  re-auditing GC safety (known SIGSEGV class: `callRlnFetcherAsync`
  cross-thread GC bug in logos-delivery — do not replicate that design).
- Pre-publish readiness: proof generation requires membership confirmed
  on-chain AND one poll-cycle having cached the merkle proof.

## Phase 4 — RLN methods + LEZ wiring in logos-libp2p-module

**Goal**: module methods to enable RLN, wire the fetcher to the wallet/rln
logos modules, set identity, and gate on readiness.

Tasks:
1. Switch `externalLibInputs.libp2p` to the plugin's `#cbind-rln`.
2. `metadata.json`: add `dependencies` on the wallet module
   (`logos_execution_zone`) and RLN module (name per its metadata.json —
   verify in `logos-lez-rln/logos-rln-module`); matching flake inputs.
3. New impl methods (plain C++, universal pattern):
   - `rlnEnable(configJson)` → `libp2p_mix_rln_enable`
   - `rlnSetIdentity(idSecretHashHex, leafIndex)`
   - `rlnIsReady()`
   - internal: install the fetcher at init — a static C callback that routes
     `(method, params)` to `modules().<rln_module>.<method>(params)`
     (get_valid_roots, get_merkle_proofs, register_member, is_registered).
     Prefer the generated async wrappers where the call pattern allows;
     synchronous is acceptable v1 because the caller is the libp2p thread,
     not the Qt thread.
4. Self-registration flow (v1, no gifter): method `rlnRegister(configAccount,
   holdingAccount, rate)` → rln module `register_member` → poll
   `is_registered` until the membership PDA lands → `rlnSetIdentity` with the
   returned leaf. (Mirror `selfRegisterRln` in logos-delivery's
   delivery_module plugin; note wallet must be `open`ed and synced —
   `sync_to_block(chain head)` — before register_member can build a valid tx.)
5. Ordering contract, enforced in code: `rlnEnable` → `start()` →
   `rlnRegister`/`rlnSetIdentity` → `rlnStartPolling` → wait `rlnIsReady` →
   mix traffic.

Acceptance: unit tests with mocked module deps; `lm methods` shows the new
surface; a single node against a LOCAL sequencer (see Phase 5 infra) reaches
`rlnIsReady() == true` after registration.

## Phase 5 — End-to-end: multi-node mix + RLN over LEZ

**Goal**: N-node mix network where every sphinx hop generates + verifies RLN
proofs against the LEZ tree; in-process test first, daemon test second.

Tasks:
1. **In-process integration test** (extend `integration_mix.cpp` style):
   spin LOCAL LSSA sequencer (build via
   `logos-lez-rln/lssa`, `cargo build --features standalone -p
   sequencer_service`; deploy tree via `lez-rln run_setup` — see
   `SIMULATION_STAGES.md` Stage 1-2 for exact commands and the
   `is_initialized → create_funded_user` short-circuit), then 5 module
   instances: enable RLN → start → register (serialize registrations or use
   per-node funded accounts — shared-account nonce collisions are a known
   silent failure) → readiness gate → mixDialWithReply → assert proof
   generation + verification counters.
2. **Daemon-mode test**: same topology via `logoscore -D` instances +
   `lgpm`-installed `.lgx`s (wallet, rln, libp2p modules), driven by a small
   script. Reuse identities pattern from this repo (static keys) rather than
   filesystem pubInfo exchange.
3. Readiness gate: do NOT use flat sleeps. Gate on: all registrations
   confirmed + `rlnIsReady` true on every node + one extra poll interval so
   valid-roots windows converge after the LAST registration.
4. Negative tests: node without membership → its hops drop packets
   ("Plugin not ready"); replayed packet → nullifier dup detection.

Acceptance: deterministic local run with all hops verifying proofs
(`Generated RLN proof successfully` / proof-verified counters ≥ path length),
repeated 3x without flakes.

Known sharp edge (do not debug blind — this is pre-diagnosed): the LEZ
`get_merkle_proofs` C++ implementation
(`logos-lez-rln/logos-rln-module/src/logos_rln_module.cpp:571-724`) assembles
its response from 4 non-atomic chain reads. Registration churn concurrent
with a fetch can yield a proof whose path-implied root is in no validRoots
window → self-verify failure → packet drop. Fixes scoped (stable-snapshot
loop + path-implied-root self-check). If Phase 5 hits
"Self-verify ... Expected one of the provided roots" during concurrent
registrations, land those fixes in logos-rln-module first. Also: stamp
cachedProof fetch time; treat cachedProof older than ~2× pollInterval as
stale (slow-poll staleness was the observed delivery vehicle).

## Phase 6 (stretch) — Scale harness convergence

Bring the module-based node back into this repo's harness:
- A `nim-test-node/mix-logos/` variant (or compose file) that runs the
  logoscore daemon + modules per pod instead of the bare binary.
- `mixnet.sh` grows a mode flag; smoke matrix extends with RLN cells.
- Testnet variant: point wallet at `https://testnet.lez.logos.co/`, use the
  shipped tree pins (TREE_ID `...e26e`) — NEVER deploy a fresh tree against
  testnet (silently fails; needs admin bootstrap). Timing floors scale ~4-10x
  vs local (60-90s blocks + finality lag); registrations take minutes each.

---

## Cross-cutting gotchas (hard-won; encode as tests where possible)

1. **`Timeout(N)` must be explicit** in any cpp-sdk `invokeRemoteMethod` call —
   a bare int silently picks the wrong overload and falls back to 20s.
2. **Never block the Qt thread** from module methods; long work belongs on the
   libp2p/chronos thread or async wrappers. The "start() RPC times out but the
   node started fine" pattern from the old sim is the symptom of getting this
   wrong.
3. **logoscore CLI arg coercion**: digit-leading non-numeric args get coerced
   to int by `logoscore call`. Wrap as `@file` or JSON-object params for
   account IDs / hex strings in daemon-mode scripts.
4. **idSecretHash, not seed**, when setting RLN identity (derivation mismatch
   between lez-rln and zerokit).
5. **Epoch/limit config must match network-wide** (rlnIdentifier,
   epochDurationSeconds, userMessageLimit) or proofs verify nowhere.
6. **`numMix >= PathLength + 2`** (sphinx path + self + destination) — already
   enforced in this repo's `env.nim:64`; keep the check in the module path.
7. **librln load-path**: prior art hit dylib `install_name` issues; the
   module-builder's `external_libraries` RPATH handling should cover it, but
   verify `otool -L`/`ldd` on the shipped `.lgx` contents.
8. **Event emission from non-Qt threads**: `logos_events:` routing from the
   libp2p thread is unverified — test early in Phase 4; if it breaks, route
   events through a queued dispatch on the module side.

## Verification command crib

```bash
# inspect a built module
./lm/bin/lm methods result/lib/libp2p_module_plugin.so --json

# daemon flow
./logos/bin/logoscore -D -m ./modules &
./logos/bin/logoscore load-module libp2p_module
./logos/bin/logoscore call libp2p_module rlnIsReady

# symbol checks
nm -gU libp2p.dylib | grep libp2p_mix_        # darwin
nm -D libp2p.so | grep libp2p_mix_            # linux

# recovered-cbind diff (what exactly was deleted)
git -C /tmp/nim-libp2p diff 7e72c0d6^ 7e72c0d6 -- cbind/
```
