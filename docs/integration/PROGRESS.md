# Progress log

One entry per work session: date, phase, what changed, what passed, blockers.

## 2026-06-12 — Phase 0 not started
- Plan authored (see PLAN.md). Recovered cbind sources extracted from vacp2p/nim-libp2p@7e72c0d6^.
- Baseline pins recorded in PLAN.md "Repos & pins".

## 2026-06-12/13 — Phase 0 COMPLETE (all acceptance criteria met)

Branch: `feat/logos-core-integration` (off `feat/mix`), docs committed `e5d6661`.

Working clones (all under `~/Waku/Logos/`):
- `nim-libp2p-mix` — adklempner fork + `upstream` remote (logos-co). Work
  branch `feat/mix-cbind` at pin `3805131`. NOTE: the pin is NOT on
  upstream/master; it lives on `upstream/fix/sphinx-replay-tag-hs`, 13 commits
  ahead of the master merge-base (carries the flake + nix CI work). Rebase
  target later is that branch or wherever it merges.
- `logos-libp2p-module` — logos-co clone at master `739f72c` (no fork yet).
- `mix-rln-spam-protection-plugin` — CORRECTION to PLAN.md: canonical repo is
  `adklempner/mix-rln-spam-protection-plugin` (main `b3e3f72`), not vacp2p.
  Cloned at main.

Build results (all green at unmodified pins):
- nim-libp2p-mix `nix build` @ 3805131: OK. Note: the default package is
  type-check only (`--compileOnly`, empty $out) — Phase 1's cbind output will
  be the first artifact-producing package.
- nim-libp2p-mix unit tests @ 3805131: 13/13 PASS (cover_traffic, crypto,
  curve25519, delay_strategy, fragmentation, mix_message, multiaddr, pool,
  seq_no_generator, serialization, spam_protection_interface, sphinx,
  tag_manager). Run via direct `nim c -r` with `--noNimblePath` +
  `--path:` args evaluated from `nix/deps.nix` (script: /tmp/run_mix_tests.sh
  pattern, worth committing in Phase 1 as a test runner).
- logos-libp2p-module `nix build` @ 739f72c: OK (lib + Qt headers).
- logos-libp2p-module `.#checks.aarch64-darwin.unit-tests` @ 739f72c:
  63 passed (includes gossipsub + kad integration tests; mix tests excluded
  by the `#if 0` gate as expected).
- Reference node image `mix-test-node:dev` built from
  `nim-test-node/mix/Dockerfile_amd64_dev` (linux/amd64): OK.

Environment gotchas discovered (darwin/arm64 host):
- nixpkgs nimble 0.18.2 SIGSEGVs in the package-list download path
  (`nimble setup`, `nimble lock` both crash; GITHUB_TOKEN irrelevant).
  Workaround: never use nimble for dep setup on this host — use the
  deps.nix `--path:` wiring (matches what nix build does anyway).
- Flake-config substituters (nix-cache.status.im) are ignored for untrusted
  users and were implicated in 2h+ silent stalls of `nix build`/`nix develop`.
  Workaround: `--no-accept-flake-config --option connect-timeout 5 --fallback`
  on every nix invocation in these repos.
- Host nim is 2.2.0 (< required 2.2.4); always build through the repos' nix
  dev shells, never the homebrew toolchain.

Next: Phase 1 — resurrect mix cbind in nim-libp2p-mix on `feat/mix-cbind`.

## 2026-06-13 — Phase 1 COMPLETE (all acceptance criteria met)

nim-libp2p-mix `feat/mix-cbind` (off pin 3805131), commits `a42ca11` +
`fd87c28`:

- Vendored nim-libp2p's `cbind/` shell from `c431993` (the exact rev this
  package pins via nix/deps.nix) and re-applied the mix deletion diff
  (`git diff 7e72c0d6 7e72c0d6^ -- cbind/`, 1015 lines). 5 files applied
  clean; 8 rejected hunks hand-ported.
- Shell drift reconciled (deletion point → c431993): `connections:
  Table[..., Connection]` → `streams: Table[..., Stream]` (Stream is an
  alias of Connection in v2.0), `connHandle` → `streamHandle`,
  `ConnectionCallback` → `StreamCallback` (Nim + C header),
  `handleConnectionRes` → `handleStreamRes`, `Curve25519Key.random(rng[])`
  → `.random(rng)`.
- libp2p_mix API drift reconciled: `readExactly`/`readLp` DestReadBehavior
  constructors now live in the root `libp2p_mix` module; `MixProtocol.new`
  takes the new optional params (defaults used + `spamProtection =
  makeSpamProtection()`); `nodePool.add(MixPubInfo.init(...))` unchanged.
- Import strategy: relative `../libp2p/...` → `pkg/libp2p/...`,
  `libp2p/protocols/mix/...` → `pkg/libp2p_mix/...`. The cbind main module
  was renamed `cbind/libp2p.nim` → `cbind/cbind.nim`: the old name shadowed
  the nim-libp2p package in the nix sandbox (pkg/ did not save us there) →
  circular import. No C-visible effect.
- NEW `cbind/mix_spam_protection_factory.nim`: `registerSpamProtectionFactory`
  / `makeSpamProtection`, mount-time-only, factory type is {.nimcall.}
  (closures must not cross onto the libp2p thread — known SIGSEGV class).
- NEW `nix/cbind.nix` (mirrors nim-libp2p's) + `nix/cbind-deps.nix`
  (taskpools pinned to nim-libp2p's rev 9e8ccc75) + `packages.cbind` flake
  output.

Acceptance evidence:
- `nix build '.#cbind'` → result/lib/{libp2p.dylib,libp2p.a} +
  result/include/libp2p.h; `nm -gU` shows all 7 `libp2p_mix_*` symbols.
- `cbind/examples/mix.c` smoke: 5 in-process nodes, nodepool populated,
  `libp2p_mix_dial_with_reply` ping → "Read 32 bytes" (SURB reply
  round-trip). Repeated after the module rename.
- Non-mix behavior: `cbindings.c` (exit 0) and `echo.c` (echo round-trip)
  both pass against the new dylib.

Notes for Phase 2:
- The module consumer expects flake attr `cbind` — matches
  `externalLibInputs.libp2p.packages.default = "cbind"` convention.
- Build helper used locally: /tmp/build_cbind.sh (deps.nix-evaluated
  --path args; nimble unusable on this host, see Phase 0 gotchas).
- The cbind C header kept the name libp2p.h and the existing 7-function
  mix surface EXACTLY as logos-libp2p-module/src/mix.cpp expects.

Next: Phase 2 — point logos-libp2p-module's `libp2p` flake input at the
feat/mix-cbind branch, remove the `#if 0` mix gate, run integration_mix.cpp.

## 2026-06-13 — Phase 2 COMPLETE (in-process acceptance met; daemon path deferred)

logos-libp2p-module `feat/enable-mix` (off master 739f72c), commit
`493cc25`; depends on nim-libp2p-mix `feat/mix-cbind` commit `5dba82c`.

Changes:
- flake.nix `libp2p.url`: `github:vacp2p/nim-libp2p` →
  `git+file:///Users/arseniy/Waku/Logos/nim-libp2p-mix?ref=feat/mix-cbind`
  (local path for iteration; switch to the pushed fork URL before sharing).
  `packages.default = "cbind"` unchanged — matches the new flake output.
- src/plugin.h: removed the `#if 0`/`#endif` around the 7 mix method
  declarations (codegen scans plugin.h, so the gate hid them from the
  universal interface). src/mix.cpp itself was already fully implemented.
- CMakeLists.txt + tests/CMakeLists.txt: uncommented `src/mix.cpp` (module
  source in both) and `tests/integration_mix.cpp`.
- ZERO C++ drift fixes needed: the cbind header re-export already carries
  the exact consumer contract (libp2p_curve25519_key_t,
  libp2p_secp256k1_pubkey_t, Libp2pMixReadBehavior, LIBP2P_MIX_READ_EXACTLY,
  the 7 libp2p_mix_* fns) — those C decls were part of the recovered patch.

Regression found + fixed (in the cbind, not the module): enabling the new
cbind initially broke 2 pre-existing QUIC tests (config_quic_transport,
integration_quic_ping_round_trip) — they failed at start(). Root cause:
the module was originally written against nim-libp2p 3f5a4dce, whose cbind
built the switch via `newStandardSwitchBuilder` (injects a QUIC default
listen addr /ip4/0.0.0.0/udp/0/quic-v1 when none given). The c431993
cbind shell I vendored uses a raw SwitchBuilder chain that only calls
withAddresses when addrs are non-empty → QUIC fell back to the implicit
TCP default and failed. Fix = restore the transport-default-address
behavior in cbind/libp2p_lifecycle_requests.nim (nim-libp2p-mix `5dba82c`).
This is the FIRST concrete instance of the c431993-vs-3f5a4dce skew the
pin matrix warned about; watch for more as later phases exercise more of
the non-mix surface.

Acceptance evidence:
- `nix build '.#checks.aarch64-darwin.unit-tests'`: 65/65 PASS, including
  `mix_dial_and_reply` (5 in-process nodes, pubInfo exchange via direct
  method calls, nodepool population, mixDialWithReply ping + SURB reply),
  `mix_nodepool_routing`, and both restored QUIC tests.

Deferred (not yet done for Phase 2):
- Daemon path verification (`logoscore -D -m ./modules` + `lgpm install`
  of the .lgx + `logoscore call libp2p_module ...`). Needs the platform
  tooling stack (logoscore + lgpm at tutorial-v3) wired up; the in-process
  check already proves the wrapper + cbind. Do this when standing up the
  Phase 5 daemon harness, or earlier if a daemon smoke is wanted first.

This completes Goal A in minimal form: mix nodes runnable as logos-core
modules (in-process). Next: Phase 3 — RLN C surface + cbind-rln in
mix-rln-spam-protection-plugin.

## 2026-06-13 — Phase 3 SUBSTANTIALLY COMPLETE (cbind-rln library builds + links; nix flake output + dedicated unit tests remain)

mix-rln-spam-protection-plugin `feat/cbind-rln` (off 5004a6c, the LEZ-onchain
lineage already migrated to the extracted libp2p_mix). Commits: a00a63f
(re-pin), c607b6d (cbind), 1fbf017 (combined main). Depends on nim-libp2p-mix
`feat/mix-cbind` 594c33e (factory moved into the package).

Which plugin lineage: the canonical Phase-3 base is the LEZ-onchain version
preserved in logos-delivery's vendor copy at commit 5004a6c (has
onchain_group_manager.nim; already imports libp2p_mix/spam_protection). The
adklempner repo's main (b3e3f72) is the OFFchain lineage pinning bundled-mix
nim-libp2p — NOT what we want. 5004a6c is reachable in the clone.

Task 1 — re-pin (DONE, verified):
- nimble now targets libp2p_mix feat/mix-cbind + nim-libp2p c431993 (single
  nim-libp2p, used only for protobuf/varint; libp2p_mix supplies SpamProtection).
- Plugin compiles with ZERO API drift against the extracted libp2p_mix; its
  full existing test suite passes (spam detect + secret recovery, proof verify,
  partial-proof cache/root tracking, epoch callbacks).
- librln finding (IMPORTANT): the stale `logos-chat/build/librln_mix_v2.0.0.a`
  has `ffi_c_string_free` only as a LOCAL symbol (linker can't use it). The
  correct one is the LEZ-RLN lineage build:
  `~/Waku/Logos/logos-chat/vendor/logos-lez-rln/logos-delivery/build/librln_mix_v2.0.0.a`
  (zerokit mix fork, global ffi_* symbols). Use that for all plugin links.

libp2p_mix factory refactor (DONE): moved the spam-protection factory registry
from nim-libp2p-mix/cbind/ into the package (libp2p_mix/spam_protection_factory.nim,
re-exported from libp2p_mix) so the plugin imports registerSpamProtectionFactory
via pkg/libp2p_mix. Phase-1 cbind smoke still green after the move.

Task 2 — RLN cbind C surface (DONE, type-checks + builds): new
src/mix_rln_spam_protection/cbind.nim exporting the 5 plan functions
(libp2p_mix_rln_enable/set_fetcher/set_identity/is_ready/start_polling).
Fetcher trampoline + LEZ get_valid_roots/get_merkle_proofs wiring ported from
logos-delivery logos_core_client.nim. set_identity uses idSecretHash DIRECTLY
(gotcha #4). Cross-thread globals are lock-guarded value types / GC-erased
pointers. NOTE: the FetchRoots/FetchProof callbacks MUST use
`{.async, gcsafe, raises: [].}` (legacy form) to match the GM's plain-Future
callback type — the `{.async: (raises: []).}` form yields InternalRaisesFuture
and fails to match (benign warning is expected; do not "fix" it).

Task 4 — combined cbind-rln (library DONE; nix output TODO): cbind/cbind_rln.nim
imports both the libp2p_mix cbind (cbind/cbind as libp2p_cbind) and this RLN
cbind into one unit. scripts/build_cbind_rln.sh builds it via the libp2p_mix
nix devshell deps + --passL the LEZ librln. Verified: links cleanly,
`nm -gU build/libp2p.dylib` shows all 5 libp2p_mix_rln_* PLUS the Phase-1 mix
surface + libp2p_new (superset, as required).

REMAINING for Phase 3:
- Task 3 detail: the LEZ callbacks are wired in the cbind (makeFetchRoots/
  makeFetchProof call setFetchCallbacks on the GM inside the factory). Verify
  end-to-end with a stub fetcher in task 5.
- Task 4 nix: wrap scripts/build_cbind_rln.sh as a flake `packages.cbind-rln`
  output emitting libp2p.{so,dylib,a} + libp2p.h + libp2p_mix_rln.h. BLOCKER:
  librln.a must enter the nix sandbox — DECISION NEEDED (vendor the ~MB .a as a
  path flake input, add a zerokit-mix build derivation, or fetch a release
  artifact). Surfaced to user.
- Task 2 detail: ship a hand-written `libp2p_mix_rln.h` (the 5 functions +
  the RlnFetcherFunc/RlnFetchCallback typedefs) for the host to include.
- Task 5: dedicated unit tests — stub C fetcher round-trip through the
  trampoline; enable→factory-registered; set_identity→credentials attached;
  is_ready transitions once a fake proof is pushed.

Acceptance status: `nm` shows libp2p_mix_rln_* + all Phase-1 symbols ✓ (via the
manual nix-devshell build, which uses the same nix-provided deps a flake would).
The nix `'.#cbind-rln'` green + mocked-fetcher unit tests are the outstanding
acceptance items.

## 2026-06-13 — Phase 3 COMPLETE (all acceptance criteria met)

Finished the two outstanding items on plugin `feat/cbind-rln` (commit 3f376c5):

- librln packaging DECISION (user-approved): vendored the LEZ zerokit-mix
  build into the repo at `vendor/librln_mix_v2.0.0.a` (~30MB; matches the
  sibling-repo convention of committing librln_*.a). The host `nm` chokes on
  its newer-Rust LLVM bitcode but the linker handles it fine.
- nix `cbind-rln` output (task 4 DONE): `flake.nix` takes libp2p_mix as a
  flake input (git+file feat/mix-cbind, nixpkgs follows); `nix/cbind-rln.nix`
  imports libp2p_mix's deps.nix + cbind-deps.nix for --path args and links the
  vendored librln. `nix build '.#cbind-rln'` → result/lib/{libp2p.dylib,
  libp2p.a} + result/include/{libp2p.h, libp2p_mix_rln.h}; nm shows all 5
  libp2p_mix_rln_* + the Phase-1 mix surface (superset).
- unit tests (task 5 DONE): tests/test_cbind_rln.nim, 4/4 pass with a stub C
  fetcher (no live LSSA): trampoline round-trip, LEZ JSON parse,
  enable->factory-registered, and set_identity->credentials + readiness gate
  flipping 0->1 after one poll cycle caches a proof from the stub. The last
  test exercises the full path makeSpamProtection -> wire fetch callbacks ->
  set_identity -> init/start -> startPolling -> poll fetches proof via stub ->
  cachedProof -> is_ready==1.

Build recipes committed: scripts/build_cbind_rln.sh (library) and
scripts/build_test_cbind_rln.sh (test). The 5 libp2p_mix_rln_* procs +
callFetcher/parseRoots/parseProof are public Nim symbols (C ABI unchanged) so
tests can drive them.

ACCEPTANCE: nix build '.#cbind-rln' green; nm shows libp2p_mix_rln_* + all
Phase-1 symbols; unit tests pass with mocked fetcher. ✓ All met.

Phase 3 done — the plugin owns all RLN C surface + the combined cbind-rln
artifact; no RLN content leaked into nim-libp2p-mix (only the generic factory
hook). Next: Phase 4 — RLN methods + LEZ wiring in logos-libp2p-module
(switch its libp2p input to #cbind-rln, add rlnEnable/rlnSetIdentity/rlnIsReady
methods, route the fetcher to the wallet/rln logos modules, self-registration
flow, ordering contract).

## 2026-06-13 — Phase 4 COMPLETE in-process (live cross-module flow deferred to Phase 5)

logos-libp2p-module `feat/enable-mix` commit 45bf2c0; consumes plugin
`#cbind-rln` (feat/cbind-rln 3f376c5).

Cross-module mechanism (confirmed via cpp-sdk/module-builder, not the plan's
aspirational `modules().*`): a universal impl gets `LogosAPI*` via
`initLogos(apiHandleHex)` (codegen passes opaque pointers as hex strings), then
constructs a HAND-WRITTEN typed wrapper that calls
`LogosAPIClient::invokeRemoteMethod(moduleName, method, args...)` with an
explicit `Timeout(N)`. Reused logos-chat-module's `liblogos_rln_module_api.h`
verbatim (no build-time dep on the rln module — runtime call by module-name
string).

Done:
- flake input libp2p -> git+file plugin feat/cbind-rln, packages.default =
  "cbind-rln". Module builds against the RLN-enabled superset library.
- src/plugin.h: forward-declares LogosAPI (keeps Qt/SDK out of the
  codegen-scanned header), adds initLogos + rlnEnable/rlnSetIdentity/
  rlnIsReady/rlnStartPolling/rlnRegister decls + the static fetcher trampoline
  + m_logosAPI/m_rlnConfigAccount members.
- src/rln.cpp: implements them. rlnEnable parses config (captures
  configAccount), calls libp2p_mix_rln_enable + set_fetcher(trampoline, this).
  rlnFetcherTrampoline routes get_valid_roots / get_merkle_proofs into the rln
  module via LiblogosRlnModule (synchronous; runs on libp2p thread, NOT Qt
  thread, per gotcha #2). rlnSetIdentity hex-decodes 32 bytes ->
  libp2p_mix_rln_set_identity (idSecretHash DIRECTLY). rlnRegister v1:
  generate_identity -> register_member (parse leaf_index) -> rlnSetIdentity.
- src/liblogos_rln_module_api.h: the rln-module client wrapper (copied from
  chat-module).
- metadata.json dependencies = [liblogos_rln_module,
  liblogos_execution_zone_wallet_module]. The builder treats these as a
  runtime/load-order declaration — build does NOT pull those modules in (no
  flake inputs needed for them at build time).
- CMakeLists + tests/CMakeLists: added src/rln.cpp + tests/integration_rln.cpp.

Acceptance evidence:
- nix '.#checks.aarch64-darwin.unit-tests': 68/68 PASS, incl. 3 new rln_*:
  rln_enable_and_readiness_gate (enable ok; is_ready false with no GM; polling
  graceful no-op), rln_set_identity_validates_hex (rejects bad/short hex;
  no-GM failure is clean), rln_register_requires_logos_api (clean failure
  without initLogos).

Ordering contract: documented in plugin.h; partially self-enforcing — set
identity / start polling / register fail cleanly before the GM exists (i.e.
before rlnEnable + mix mount). Strict state-machine enforcement not added (not
needed for the natural failure modes).

Deferred to Phase 5 (need the live rln module + LSSA sequencer, can't run in
the hermetic unit-test sandbox or without a daemon):
- The cross-module fetcher actually returning roots/proofs (needs a loaded rln
  module to answer invokeRemoteMethod).
- rlnRegister end-to-end (needs wallet open+synced + rln module + sequencer).
- "single node against LOCAL sequencer reaches rlnIsReady()==true after
  registration" — the plan's live Phase-4 acceptance, folded into Phase 5.
- Adding rln + wallet modules as flake inputs for daemon assembly (Phase 5/6).
- `lm methods` listing: lm reports no methods for the universal plugin on
  darwin (Qt-loading quirk — shows none even for the pre-existing mix/gossipsub
  surface), so the unit tests (which call the methods) are the surface proof.

Next: Phase 5 — end-to-end multi-node mix + RLN over LEZ (in-process test with
a local LSSA sequencer first, then daemon-mode), readiness gates, negative
tests.

## 2026-06-13 — Phase 5 RECON (infrastructure mapped; implementation path is a fork — awaiting direction)

Inventory of what's live on this host:
- LSSA sequencer RUNNING on :3040, healthy (getLastBlockId -> 2376). Prebuilt
  sequencer_service + run_setup binaries exist under lssa/ and lez-rln/.
- A full mix+LEZ chat sim is ACTIVELY RUNNING (the OLD hand-FFI delivery
  stack): logos-chat/simulations/mix_lez_chat/.sim_state has live node0.log
  (27MB), chat_sender/receiver logs updating. So the entire Phase-5 infra
  (sequencer + deployed tree + funded accounts + daemon + modules) works —
  but it drives the delivery node, not the new logos-libp2p-module.
- logoscore CLI available via logos-workspace/scripts/logoscore.
- testnet config/payment account fixtures present under logos-lez-rln/testnet/.

Key technical facts established for Phase 5:
- libp2p_mix's mix protocol DOES per-hop proof gen+verify when a SpamProtection
  is mounted (mix_protocol.nim:137-150 generate at send; 179-243 verify at each
  intermediate/exit hop). So multi-node mix + RLN proofs is real once each node
  has a mounted MixRlnSpamProtection with a usable membership.
- libp2p_mix already has the multi-node-mix-with-spam in-process pattern:
  tests/component/test_spam_protection.nim uses setupMixNodes(... 
  spamProtectionRateLimit ...) with a STUB SpamProtection (tests/
  spam_protection_impl.nim). The new work is swapping in the real RLN
  MixRlnSpamProtection over a consistent tree.
- OffchainGroupManager has direct register()/registerWithLimit()/
  handleMembershipUpdate()/restoreMemberFromKeystore() — so an in-process test
  can build IDENTICAL offchain trees on N nodes deterministically (no
  sequencer), giving a shared root so cross-hop verifyProof passes.
- The C++ module's onchain fetcher path (rlnEnable -> trampoline -> rln module)
  CANNOT be exercised in a hermetic unit test: it needs a loaded rln module to
  answer invokeRemoteMethod, i.e. the daemon. So a module-level in-process E2E
  is not possible; it's either Nim-level (offchain tree) or daemon-level.

Three viable Phase-5 paths (a fork — each is a large, distinct effort):
  A. In-process Nim E2E (plugin component test): N mix switches each mounting
     the real MixRlnSpamProtection (offchain), register the same N members on
     every node -> identical root -> send mix ping(s) -> assert per-hop proof
     gen+verify + a negative test (non-member hop drops / replay nullifier dup).
     Deterministic, no sequencer/daemon. Needs: extend libp2p_mix setupMixNodes
     (or build nodes manually in the plugin) to inject a custom SP, plus careful
     RLN-tree-consistency setup. Medium-large; fully reproducible; proves the
     core "every hop verifies a proof" claim. Does NOT exercise LEZ/onchain or
     the C++ module fetcher.
  B. Sequencer-backed in-process test: onchain GM + a C++/Nim test fetcher that
     talks to the running :3040 sequencer directly (registers N members, serves
     get_valid_roots/get_merkle_proofs). Exercises real LEZ + the onchain GM,
     but the fetcher reimplements what the rln module does (register + queries).
     Large; touches the pre-diagnosed get_merkle_proofs non-atomicity.
  C. Daemon-mode E2E (the plan's task 2, also Phase 6 vehicle): package the new
     logos-libp2p-module as a .lgx, stand up logoscore -D with wallet + rln +
     libp2p modules, drive via logoscore call. Most faithful; largest effort
     (needs rln+wallet .lgx builds — risc0/zerokit — and a daemon harness; can
     likely adapt the existing run_simulation_lgx.sh which already assembles the
     sequencer+modules+daemon for the delivery node).

Pre-diagnosed sharp edge still pending (from PLAN.md): the LEZ get_merkle_proofs
non-atomicity (logos-rln-module logos_rln_module.cpp:571-724) — land the
stable-snapshot + path-implied-root self-check fix if paths B/C hit
"Self-verify ... Expected one of the provided roots" during concurrent
registrations. Not relevant to path A (deterministic offchain tree).

Status: Phases 0-4 complete and verified. Phase 5 implementation paused at this
recon checkpoint pending a choice of path (A/B/C), since each is a major effort
and they prove different things.

## 2026-06-13 — Phase 5 path C (daemon E2E): foundational milestones done

User chose path C (daemon-mode .lgx E2E). Progress on logos-libp2p-module
`feat/enable-mix` (commits 5e21ceb, then daemon_smoke in test-node f3fe0a3):

DONE + verified:
- `nix '.#lgx'` builds the RLN-enabled module bundle: manifest +
  variants/darwin-arm64-dev/{libp2p.dylib (31MB, cbind-rln + librln linked),
  libp2p_module_plugin.dylib}. The plugin links @rpath/libp2p.dylib as a real
  LC_LOAD_DYLIB (NOT flat-namespace), so no DYLD-preload dance is needed
  (simpler than the delivery module).
- Had to revert metadata `dependencies` to [] to make the .lgx build: declaring
  deps makes the universal codegen emit logos_sdk.h #including the dep modules'
  *_api.h, which needs them as flake inputs. Our cross-module calls use a
  hand-written wrapper (runtime invokeRemoteMethod by name), so the build-time
  dep is unnecessary; the daemon harness loads modules in order manually.
- DAEMON SMOKE PASSES (docs/integration/scripts/daemon_smoke.sh): the
  RLN-enabled module loads in a real logoscore daemon
  (/nix/store/z03ains...-logos-logoscore-cli/bin/logoscore, the binary the live
  sim uses) and starts a working mix node. `logoscore call libp2p_module start`
  -> ok; `call peerInfo` -> {peerId, /ip4/127.0.0.1/tcp/<ephemeral>}; log shows
  "Started libp2p node" with /meshsub + /ipfs/kad + ping protocols, kad
  bootstrap complete; `call stop` -> ok. Isolated config/modules dir + ephemeral
  port so it doesn't disturb the running sim.

Infra available for the full flow: logoscore binary (above); wallet .lgx
(/nix/store/xgvg6jq...-logos-execution-zone-module-lgx-dev) and rln .lgx
(/nix/store/77ka36c...-logos-rln-module-lgx-dev) in the sim's ~/.cache/sim-lgx;
sequencer live on :3040; install_lgx/daemon/load/call machinery proven (sim
run_simulation_lgx.sh stages 4-6 + this module's tests/integration_e2e/
openmetrics_e2e.sh).

KEY GAP — RESOLVED (commit 4955373): the cross-module RLN fetcher in daemon
mode needs LogosAPI, but the daemon never calls initLogos(hex); the universal
flow provides it via the LogosModuleContext mixin (modules().api).
Libp2pModuleImpl now extends LogosModuleContext; ensureLogosAPI() prefers the
explicit hex handle else lazily takes modules().api. logos_sdk.h (codegen-only,
defines LogosModules) is guarded with __has_include so rln.cpp compiles in the
unit-test build (fallback absent) and the daemon/.lgx build (fallback active).
Verified: unit-tests 68/68; .lgx rebuilds with modules().api compiled; daemon
smoke still loads + start/peerInfo/stop ok.

REMAINING for the full path-C E2E (the hard part — multi-iteration, best with
the user's sim NOT running to avoid sequencer/module contention):
1. [DONE] Libp2pModuleImpl : public LogosModuleContext + modules().api.
2. Harness loading wallet -> rln -> libp2p_module (3 daemons or 1 multi-module),
   then per node: rlnEnable(config) -> start -> register (gifter or self) ->
   readiness gate (rlnIsReady + one poll cycle) -> mixDialWithReply -> assert
   proof gen/verify counters. Adapt sim stages 5-6 (gifter registration,
   sequencer txs, the pre-start setRlnConfig trampoline-install ordering).
3. Land the pre-diagnosed get_merkle_proofs stable-snapshot fix in
   logos-rln-module if "Expected one of the provided roots" self-verify races
   appear during concurrent registration.
4. Negative tests (unregistered hop drops; replayed nullifier dup).

Net: the new module is proven daemon-loadable + runs a mix node under logoscore
— the foundational path-C claim. The full RLN-over-LEZ multi-node daemon run is
the remaining work, clearly scoped above.

## 2026-06-13 — Docker path for an ISOLATED full sim (answers "run the whole sim in docker?")

YES — the sim already fully containerizes, isolated from the host's running sim,
and (key) builds everything for LINUX inside the container, which sidesteps the
"this darwin host can't cross-build x86_64-linux nix derivations" blocker.

Pieces (in logos-chat):
- `.github/Dockerfile.sim`: 2-stage. Builder (catthehacker/ubuntu + nix + rust +
  cargo-risczero) nix-builds logos-rln-module, logos-execution-zone-module
  (wallet), logoscore (logos-liblogos), delivery + chat modules; packages the
  runtime nix closure into a slim stage 2. sequencer + run_setup are built from
  source at RUN time (builder-stage binaries crash cross-stage).
- `scripts/run_in_docker.sh`: builds/pulls the image
  (ghcr.io/adklempner/logos-chat-sim:latest), runs the container, clones the
  chat branch, symlinks the prebuilt modules, builds the sequencer, then runs
  `run_simulation.sh --fresh`. Fully self-contained: its OWN sequencer + modules
  inside the container — zero contention with the host sim.
- `setup_and_run.sh` already has the Docker/Linux path (detects /.dockerenv,
  disables nix sandbox, sets LIBCLANG_PATH). PLATFORM resolves to
  linux-x86_64-dev there (run_simulation_lgx.sh:278).

`logos-docker` (git@github.com:logos-co/logos-docker) is a DIFFERENT, lighter
thing: a generic Linux runtime image (logoscore/lgpm/lgpd as AppImages) that
`lgpd download`s the PUBLISHED modules (delivery/storage/blockchain/openmetrics
— the OLD stack). Not our RLN mix modules. Useful as a runtime pattern, not as
our sim.

To run OUR new module-based mix node in Docker (the clean isolated E2E):
1. Make our three local branches buildable in-container. They currently use
   local-path flake inputs (git+file:///Users/arseniy/...): nim-libp2p-mix
   feat/mix-cbind, mix-rln-spam-protection-plugin feat/cbind-rln,
   logos-libp2p-module feat/enable-mix. Either PUSH them to GitHub forks and
   repoint the flake inputs at the pushed refs (cleanest for a clone-based
   Dockerfile), or COPY the repos into the build context. (Pushing is
   outward-facing — needs user OK + a fork for logos-libp2p-module, which is
   currently a plain logos-co clone with no fork remote.)
2. Add a Dockerfile.sim stage that `nix build .#lgx` of logos-libp2p-module for
   linux (pulls the plugin + nim-libp2p-mix transitively) → linux .lgx.
3. A sim variant / run script that loads wallet -> rln -> libp2p_module and
   drives the NEW module's API (initLogos via modules().api is automatic now;
   rlnEnable -> start -> register -> readiness -> mixDialWithReply) instead of
   the delivery node's open/createNode/selfRegisterRln. Reuse the gifter /
   sequencer / readiness-gate machinery from run_simulation_lgx.sh stages 5-6.

This is the recommended vehicle for the full path-C E2E: reproducible, isolated,
and it solves the linux cross-build problem. Effort: medium-large (push/copy +
Dockerfile stage + the new-module driver script), but no host contention.

## 2026-06-13 — Linux .lgx cross-build DONE (COPY-based, no push)

User chose COPY (no GitHub push). docker/Dockerfile.lgx-linux +
docker/build_lgx_linux.sh (committed, 15f337b) build the RLN-enabled module
.lgx for Linux from the local unpushed branches:
- Stage the 3 repos into a clean context (rsync excludes .git/build/nimcache/
  result*/*.dylib AND the darwin vendor/librln*.a).
- In-container: build a LINUX librln_mix via `cargo build --release -p rln` from
  vacp2p/zerokit @ v2.0.0 (the vendored librln is darwin-only — the one real
  cross-build wrinkle), drop it at plugin vendor/librln_mix_v2.0.0.a.
- `nix build path:/src/logos-libp2p-module#lgx` with the local git+file inputs
  repointed at the copies via `--override-input libp2p path:... --override-input
  libp2p/libp2p_mix path:...`. No flake.nix/lock edits needed.

Result (VERIFIED): /tmp/lp2p-out/libp2p_module.lgx — manifest +
variants/linux-arm64-dev/{libp2p.so, libp2p_module_plugin.so}, both ELF
aarch64; all 5 libp2p_mix_rln_* symbols in libp2p.so. ~237s in-container.
NOTE: arch is linux-ARM64 (native to the arm-mac Docker VM). The runtime
container for the E2E must match (arm64); Dockerfile.sim builds its
wallet/rln/logoscore/sequencer in-container so arch will match automatically.

This clears the hard blocker (darwin host can't cross-build linux nix
derivations). REMAINING for the containerized E2E:
1. A runtime image / compose that has logoscore + wallet .lgx + rln .lgx (build
   these arm64-linux the same COPY way, or reuse logos-chat Dockerfile.sim's
   builder which already produces them) + our linux libp2p_module.lgx +
   sequencer.
2. The new-module driver (load wallet->rln->libp2p; rlnEnable->start->register
   ->readiness->mixDialWithReply), reusing run_simulation_lgx.sh stages 5-6
   gifter/sequencer/readiness machinery.
3. Negative tests + the get_merkle_proofs stable-snapshot fix if races appear.

## 2026-06-13 — Linux daemon smoke: blocked on Docker disk (findings recorded)

Built docker/Dockerfile.daemon-smoke-linux (logoscore + our linux .lgx + smoke).
Findings before the disk wall:
- logos-liblogos's `logoscore` does NOT accept `-D` ("Unknown option 'D'"). The
  correct daemon binary is `logos-logoscore-cli` (what the sim/host use). The
  smoke Dockerfile now builds `github:logos-co/logos-logoscore-cli`.
- Headless container Qt needs QT_QPA_PLATFORM=offscreen (added to daemon+client
  in daemon_smoke.sh) or logoscore hangs.
BLOCKER: Docker VM disk exhausted. Docker.raw grew to 119GB; host APFS pool at
99% (172MiB free). `docker build`/`prune` fail with input/output error (VM fs
full). Needs Docker Desktop remediation (increase disk image size, or
Clean/Purge data / factory-ish reset of the VM) + reclaim host pool. The linux
.lgx (verified) + the smoke harness are ready; rerun once disk is freed.

## 2026-06-14 — Linux daemon smoke GREEN (Docker recovered)

Docker VM corruption (buildkit DB I/O errors after the disk-full event) was
cleared by restarting Docker Desktop (quit/relaunch) once host pool had space
(nix-collect-garbage). prune then worked. The host sim is native (not
containerized) so the Docker restart didn't touch it.

VERIFIED: the RLN-enabled module, cross-built for Linux in Docker, loads in a
Linux logos-logoscore-cli daemon and runs a mix node:
  load-module libp2p_module -> ok
  call start -> {"success":true}
  call peerInfo -> {peerId, /ip4/127.0.0.1/tcp/<ephemeral>}
  call stop -> ok
daemon log: "Module loaded: libp2p_module" + "Started libp2p node" (meshsub/
kad/ping). Image: docker/Dockerfile.daemon-smoke-linux (logos-logoscore-cli +
QT_QPA_PLATFORM=offscreen). This is the Linux counterpart of the darwin daemon
smoke — path C's "module runs in a real daemon" claim now holds on Linux too.

Path C remaining: the multi-module RLN E2E (wallet + rln .lgx built the same
COPY/linux way + sequencer + driver: rlnEnable->start->register->readiness->
mixDialWithReply). Disk note: keep an eye on Docker.raw growth; prune between
heavy builds.

## 2026-06-14 — testnet E2E build: harness + all env fixes committed; build gated on a stable Docker env

Switched Goal-B validation to the hosted LEZ testnet (no local sequencer) —
saves ~19GB risc0/sequencer/lssa build + avoids the local-zkvm toolchain (see
the earlier testnet-vs-local analysis). Committed harness:
- docker/testnet/single_node_readiness.sh — the driver (Phase-4 live acceptance
  via testnet): load wallet->rln->libp2p, open+sync wallet, rlnEnable(onchain
  LEZ, config GD4Ao...), start + mixSetNodeInfo, rlnRegister(config/wallet/rate
  from shipped testnet fixtures), rlnStartPolling, gate on rlnIsReady (~1h cap).
- docker/Dockerfile.testnet-e2e — logoscore CLI + wallet & rln (clone of
  logos-lez-rln, Dockerfile.sim recipe minus sequencer/risc0) + our linux .lgx
  + testnet fixtures from the clone.

THREE build-env issues found + FIXED in the Dockerfile across iterations:
1. nixos/nix (alpine) base has no /bin/bash -> SHELL line failed. Fix: use
   catthehacker/ubuntu base (same as Dockerfile.sim).
2. zerokit/lez-rln-ffi cargo build needs build-essential + clang/libclang
   (bindgen) -> add apt deps + LIBCLANG_PATH=/usr/lib/llvm-18/lib.
3. nix builds hung ~2h with 0% CPU -> the nix-cache.status.im flake substituter
   stalls for untrusted users (the Phase-0 gotcha). Fix: accept-flake-config=
   false + connect-timeout=5 + fallback in container nix.conf + --no-accept-
   flake-config --fallback on every nix build.

BLOCKER (environmental, not code): Docker on this machine is unstable under
these heavy builds — repeated VM events this session: Docker.raw ballooned to
119GB, buildkit metadata_v2.db I/O errors (full disk), and finally
`docker buildx ls` -> BUILDKIT status=error with the VM at 0% CPU. Each
testnet-e2e build runs 1-2h and the VM has wedged twice (needed Docker Desktop
restart once). The host APFS pool is shared + tight (~11GB free, /nix 41GB).

RECOMMENDATION: run docker/Dockerfile.testnet-e2e in a CLEAN, ample environment
rather than this disk-constrained Docker VM:
- CI is the natural home — logos-chat already runs Dockerfile.sim in GitHub
  Actions (catthehacker/ubuntu runner). The same runner builds our image with
  no disk/VM-corruption issues.
- Or locally after increasing Docker Desktop's disk image size and (ideally)
  running it attended so a wedged buildkit can be restarted promptly.
Remaining after a green build: validate the wallet/rln module-install layout
(Dockerfile lines ~61-68, the one unverified step), run the slow testnet
readiness (registration minutes, confirmation up to ~1h), then extend to
multi-node mixDialWithReply with proof-gen/verify asserts + negative tests.
