### What the user achieves

A developer runs 5 `logoscore` nodes as a docker-compose stack and watches **every node
obtain an RLN membership through allocated (gifted) on-chain registration** on the hosted
LEZ testnet. One node — `relay1`, the **gifter** — is the only node that holds a funded
wallet. It registers its own membership, then serves a libp2p allocation protocol
(`/logos/rln/membership/1.0.0`). The other four nodes **authenticate to it with an EIP-191
signature and receive a distinct on-chain membership without ever funding or signing a
transaction themselves**. The client generates its own RLN identity locally and sends only
the identity *commitment*; the gifter funds and signs the registration and returns the
allocated leaf.

The memberships are then exercised in context: the 5 nodes form a 3-hop Sphinx mix
(sender + 3 relays + destination), send an RLN-protected message through the mix with a
SURB reply back, and RLN spam protection is enforced **per hop on both legs** — each relay
verifies the incoming proof and regenerates a fresh one for the next hop, which is why
every mix node must be a member. The headline is the allocation; the mix is the setting
that makes per-node membership necessary and useful.

### Why it matters

**Self-service on-chain RLN registration is a barrier to entry.** To join an RLN group the
normal way, a user must hold funds, pay gas, and submit a blockchain transaction from their
own key — and doing so over a public RPC leaks the correlation between their IP and their
RLN identity. [LIP-158 (RLN Membership Allocation)](https://lip.logos.co/anoncomms/raw/rln-membership-service.html)
removes the first barrier: a **membership provider registers the client's identity
commitment on the client's behalf**, so the client needs no funds, no chain access, and no
wallet of its own. The provider never learns the client's RLN secret key — only the public
commitment it registers. This sim demonstrates exactly that primitive end to end on a live
testnet: one funded account (`relay1`) registers four other nodes' independent identities,
and those nodes hold no funds and sign no transactions.

**This is possible because RLN is implemented natively in the Logos Execution Zone (LEZ).**
The whole RLN group lives on the LEZ testnet as risc0 zkVM guest programs plus a set of
accounts derived from `(registration_program_id, tree_id)` — the config account, the Merkle
tree account, and the credit-token accounts are all program-derived. `register_member` is a
**real sequencer transaction that spends RLNTOK** (the test token) and grows an on-chain
Merkle tree; membership and proofs are read back from that on-chain state. Nothing here is
mocked. Building RLN-over-LEZ — the funder≠identity decoupling, the on-chain tree, the proof
fetch — is what made a gifted allocation flow possible at all.

**Mix DoS protection is the secondary payoff.** A mix network gives sender anonymity, but
that same anonymity turns a relay into a free spam amplifier: it can't see who sent a packet,
so it can't rate-limit by identity. [LIP-144 (RLN DoS Protection for Mixnet)](https://lip.logos.co/anoncomms/raw/mix-spam-protection-rln.html)
closes the gap with a **per-hop** proof: each relay re-proves membership for the next hop
rather than carrying one sender proof end to end, so a spammer can't dodge detection by
splitting traffic across paths. A member may send at most `userMessageLimit` messages per
epoch; exceeding it leaks their secret key (the slashing incentive), while honest traffic
stays anonymous. Because the protection is per hop, every mix node must be a member — which
is precisely why cheap, low-friction membership allocation matters for a mixnet.

### Key components

- `dst-libp2p-test-node` (this repo, branch `feat/logos-core-integration`): the
  docker-compose stack, `bootstrap.sh`, `orchestrate.sh` (drives all five daemons over
  `logoscore call`), the image recipe (`Dockerfile.testnet-e2e`), the host-side key helper
  (`keys.py`), and the EIP-191 auth fixtures (`fixtures/gifter_auth/`).
- `logos-rln-gifter` (sibling, branch `master`): the **standalone RLN membership gifter**
  libp2p protocol module. A self-contained nim-libp2p `LPProtocol` (not tied to any
  delivery/waku stack) that implements `/logos/rln/membership/1.0.0` (LIP-158): server-side
  EIP-191 allowlist authentication + allocation, and a client that dials, authenticates, and
  adopts the granted membership. Superset-linked into the combined `.lgx` alongside mix +
  RLN. EIP-191 auth is used **only** for the client↔gifter handshake; RLN spam-protection
  proofs are unchanged.
- `logos-libp2p-module` (sibling, branch `feat/enable-mix`): the universal Logos Core module
  wrapping nim-libp2p C bindings. Exposes the mix + RLN + gifter methods the orchestrator
  calls: `rlnEnable`, `rlnGifterServe`/`rlnGifterRequest` (the allocation glue), `rlnIsReady`,
  `mixSetNodeInfo`, `mixNodepoolAdd`, `mixRegisterDestReadBehavior`, `mixDialWithReply`,
  `streamWrite`/`streamReadExactly`. Built into the Linux `.lgx` the entrypoint overlays.
- `nim-libp2p-mix` (sibling, branch `feat/mix-cbind`): reference impl of LIBP2P-MIX (LIP-99).
  Sphinx packet construction/handling (`PathLength = 3`, hardcoded), SURB reply path, LIONESS
  payload encryption, cover traffic, and the pluggable `SpamProtection` interface. Wire
  format is `[Sphinx packet][σ]`: the RLN proof σ is appended after the Sphinx packet; each
  hop strips σ, peels one Sphinx layer, then appends a fresh σ for the next hop.
- `mix-rln-spam-protection-plugin` (sibling, branch `feat/cbind-rln`): concrete RLN
  implementation of `SpamProtection` (LIP-144) over zerokit v2.0.0 FFI (RLN-v2 / Poseidon,
  Merkle depth 20). `generateProof(bindingData)` / `verifyProof(proof, bindingData)`, bound
  to the Sphinx packet bytes so a relay can't replay a proof on a different packet. Detects
  double-signaling via a nullifier log. This plugin is **unchanged** by the gifter work — it
  keeps generating/verifying RLN proofs from whatever registered identity the node holds; the
  only thing that changed is *how the node acquired that identity*.
- `logos-lez-rln` (cloned inside the image, branch `feat/rln-stateless-v2.0.2`, overlaid with
  this repo's vendored `docker/vendor/{lssa,lez-rln-ffi,logos-rln-module}`): supplies the
  wallet + RLN logos-core modules (`liblogos_execution_zone_wallet_module`,
  `liblogos_rln_module`) as `.lgx` bundles, and the deployment profile (RLN tree + wallet)
  baked into the image. Its RLN module implements `register_member` — the funder≠identity
  on-chain registration the gifter drives.

### Repository

https://github.com/adklempner/dst-libp2p-test-node/tree/feat/logos-core-integration

### Runtime target

testnet v0.2

### Prerequisites

- OS: Linux or macOS (scripts are bash-3.2 compatible)
- Docker running, with ~30 GB free in its VM (the image is ~17 GB; a cold Nix build needs
  headroom)
- `git` + internet (GitHub, Nix caches, `https://testnet.lez.logos.co/`)
- No SSH keys, no manual keystores, no local toolchain. `bootstrap.sh` clones/builds
  logoscore, the wallet/rln modules, the libp2p `.lgx` (mix + RLN + gifter), and bakes the
  deployment profile. The sibling repos are public forks; SSH is the default clone transport,
  but HTTPS works without keys (see below). The EIP-191 auth fixtures are demo keys checked
  into this repo — NOT for production.

### Commands and expected outputs

```sh
### First bootstrap (clone siblings + build the .lgx + base image)

git clone git@github.com:adklempner/dst-libp2p-test-node.git
cd dst-libp2p-test-node

# Clones 4 sibling repos (SSH) next to this one, builds the Linux libp2p .lgx
# (mix + RLN + gifter), and builds the base image `lp2p-mix-e2e`.
# ~30-45 min first time; re-runs fast.
bash docker/testnet/mix_e2e/bootstrap.sh

# The forks are public — clone + bootstrap over HTTPS instead if you have no SSH keys:
#   git clone https://github.com/adklempner/dst-libp2p-test-node.git
#   REPO_BASE=https://github.com/adklempner bash docker/testnet/mix_e2e/bootstrap.sh

cd docker/testnet/mix_e2e

### PHASE=1: prove Sphinx routing through our module (RLN OFF)

# Bring up 5 nodes, mesh the mix pool, exchange request/reply round-trips through the
# 3-hop mix with RLN disabled. Fast — no registrations. Proves the request/reply path
# and mesh work before adding RLN and allocation.
PHASE=1 bash orchestrate.sh

# Expected (abridged): 5 daemons up, per-node peerId/mixpub/lppub, mesh, dest-read-behavior,
#   sender->dest: 3/3 replies received
#   dest->sender: 3/3 replies received
#   PASS: every round-trip got a reply (sender->dest=3 dest->sender=3).
#   DONE (PHASE=1 NEG=0 MSG_COUNT=3 BIDIR=1)

### PHASE=2: gifted per-hop RLN over the mix (the headline run)

# relay1 self-allocates its membership, then serves the gifter protocol. relay2/relay3/
# dest/sender each authenticate (EIP-191) and receive a gifted on-chain membership. Then
# src and dest each do MSG_COUNT (default 3) request/reply round-trips over the mix,
# RLN-enforced on BOTH legs. ~15 min; the 5 sequential on-chain registrations dominate.
PHASE=2 bash orchestrate.sh

# Expected (abridged) — the allocation is the headline; watch these lines
# (leaf indices are illustrative; they accumulate on the shared tree across runs):
#   config=FUhP8quu... holding(funder)=9xhSHTku...
#   === per-node setup (...) ===
#     relay1 wallet synced to <block>
#     relay1 peerId=16Uiu2HAm... leaf_opt=20 leaf_actual=20 confirmed=true rlnIsReady=True
#     relay1 gifter service mounted (/logos/rln/membership/1.0.0, allowlist=4 clients)
#     relay2 peerId=16Uiu2HAm... leaf_opt=21 leaf_actual=21 confirmed=true rlnIsReady=True
#     relay3 ... leaf_opt=22 leaf_actual=22 confirmed=true rlnIsReady=True
#     dest   ... leaf_opt=23 leaf_actual=23 confirmed=true rlnIsReady=True
#     sender ... leaf_opt=24 leaf_actual=24 confirmed=true rlnIsReady=True
#   === rlnIsReady status (each node was confirmed ready before the next registered) ===
#      relay1=True relay2=True relay3=True dest=True sender=True
#   === exchange: 3 request/reply round-trip(s) per initiator (BIDIR=1) ===
#     sender->dest: 3/3 replies received
#     dest->sender: 3/3 replies received
#   === observe: RLN proofs (forward request + SURB reply legs) ===
#     relay1: generated=9 verified=9   relay2: generated=11 verified=11  ... (all >0)
#     replies: sender->dest=3 dest->sender=3 ; total verifications=36 ; sender proofs=3
#     gifter(relay1): 'RLN gifter registration succeeded' x4 (expect 4 in the happy path)
#   PASS: every round-trip got a reply (sender->dest=3 dest->sender=3).
#   DONE (PHASE=2 NEG=0 MSG_COUNT=3 BIDIR=1)

# 4 gifted + 1 self = 5 distinct leaf_actual values, leaf_opt == leaf_actual on every node,
# all rlnIsReady=True. relay1's daemon log shows "handling RLN gifter request" and "RLN
# gifter registration succeeded" (x4); each client's log shows "RLN membership granted".

### PHASE=2 NEG=1: negative test (no membership -> rejected)

# Gift relays + dest, but the SENDER never asks the gifter (rlnEnable + mix set up, no
# membership / no proof). Its mixDial must be rejected and the message must NOT reach dest.
PHASE=2 NEG=1 bash orchestrate.sh
#     sender peerId=16Uiu2HAm... UNREGISTERED (negative) rlnIsReady=False
#     sender->dest: 0/3 replies received
#   PASS (negative): sender got 0 replies and generated 0 proofs -> rejected (NEG=1).

### PHASE=2 NEG=2: negative test (allocation AUTH refused)

# The sender DOES ask the gifter, but signs with a key that is NOT on the allowlist. The
# gifter refuses authentication -> no membership -> rejected. Exercises the allocation
# authentication gate specifically (vs NEG=1 which just skips the request).
PHASE=2 NEG=2 bash orchestrate.sh
#     sender peerId=16Uiu2HAm... REFUSED (negative, non-allowlisted key) rlnIsReady=False
#     sender->dest: 0/3 replies received
#   PASS (negative): sender got 0 replies and generated 0 proofs -> rejected (NEG=2).

### Teardown
docker compose down
```

### Success command

```sh
PHASE=2 bash orchestrate.sh   # in docker/testnet/mix_e2e, after bootstrap.sh
```

### Expected result

`VERDICT: PASS`. The allocation lines come first and are the point: **5 distinct on-chain
leaves, `leaf_opt == leaf_actual` and `confirmed=true` on every node, all
`rlnIsReady=True`** — four of them gifted (`relay2/relay3/dest/sender`) from a single funder
(`relay1`), which registered its own leaf and then served four more. relay1's daemon log
shows `handling RLN gifter request` and `RLN gifter registration succeeded` four times; each
client logs `RLN membership granted`. Then the mix exercise: `sender->dest: 3/3` and
`dest->sender: 3/3` replies received; every node logs `Generated RLN proof successfully` and
`Proof verified successfully` at least once; total `Proof verified successfully` ≈
`6 * MSG_COUNT * directions` (≈36 for the default 3×2). Exit code 0. The negative runs print
`PASS (negative)` with `sender->dest: 0/3` and 0 sender proofs — `NEG=1` because the sender
never asked for a membership, `NEG=2` because the gifter refused its (non-allowlisted) auth.
Peer IDs and leaf indices are non-deterministic across runs; counts, log strings, and the
verdict are stable.

> Note: reply bytes are UTF-8-corrupted over `--json`, so a "reply received" means
> `streamReadExactly` returned `success:true` (the SURB round-trip completed), not a
> byte-for-byte compare. The log-side `Proof verified successfully` counts corroborate
> per-hop RLN.

### Configuration details

```sh
# Knobs (all optional; defaults shown), passed as env to orchestrate.sh:
PHASE=2            # 1 = mix routing only (RLN off); 2 = gifted per-hop RLN
NEG=0              # with PHASE=2: 1 = sender never asks the gifter; 2 = sender asks with a
                   #   NON-allowlisted key (allocation auth refused). Both -> sender rejected.
MSG_COUNT=3        # request/reply round-trips per initiator
BIDIR=1            # 1 = both src and dest initiate; 0 = sender->dest only
MSG_PROTO=/ipfs/ping/1.0.0   # echo proto used for the round-trip
READ_SIZE=32       # bytes read back (matches the ping echo)
MSG_INTERVAL=0     # seconds between round-trips
RATE=100           # RLN userMessageLimit (messages per member per epoch)
RPC_URL=https://testnet.lez.logos.co/   # LEZ testnet endpoint

# Keep MSG_COUNT well under RATE (<=~100). Exceeding the per-epoch limit is exactly what RLN
# rejects. epochDurationSeconds=10.0 is set in rlnEnable.

# Which deployment (RLN tree + wallet) the gifter funds registrations from is baked into the
# image as a deployment profile (docker/testnet/deployments/<name>, default shared-5ade).
# Select another provisioned profile at build time:
docker build -f docker/Dockerfile.testnet-e2e --build-arg DEPLOYMENT=<name> -t lp2p-mix-e2e .

# Single-node RLN readiness (no mix, no gifter — self-registration) is the image default:
docker run --rm lp2p-mix-e2e
```

### Failure modes and limits

- **No local fallback.** Everything needs `https://testnet.lez.logos.co/` reachable (chain
  head, wallet sync, registration). If it's down, registration stops at the barrier. No
  offline mode.
- **Gifter wallet out of funds.** All five registrations are funded by the deployment's
  **payment account** (held only by `relay1`). Each register costs `price_per_unit * rate`
  RLNTOK, so the funded account is finite. Symptom (auto-detected in relay1's log):
  `Insufficient balance`, registrations stop confirming. Fix: provision a fresh funded
  payment account on the **same tree** and rebuild the image (the daemons sign with the baked
  wallet, so a new payment account must be baked in) — `orchestrate.sh` prints the exact
  `provision.sh --tree same --adopt-wallet` + `docker build --build-arg DEPLOYMENT=` commands.
- **RLN tree full (~10k members at rate 100).** Symptom (auto-detected): `Would exceed max
  total rate limit`. `tree_id` is env-driven (no source edits): provision a brand-new tree
  and rebuild against it. See `../deployments/README.md`.
- **Allocation is serialized.** Each client's on-chain confirmation barrier
  (`is_member_registered` → `registered:true`) must pass before the next client requests, so
  the single gifter wallet's transactions stay nonce-ordered and each membership lands on a
  distinct leaf. Symptom if bypassed: `!! LEAF MISMATCH`, then relays drop those proofs.
- **Each PHASE=2 run allocates 5 fresh identities**, accumulating leaves on the shared tree.
- **Loopback trap (fixed, don't regress).** Nodes listen on their container IP, not
  `0.0.0.0` (which also advertises `127.0.0.1`, sending mix next-hop / SURB / gifter-dial
  traffic to loopback → peer-id mismatch → dropped). The entrypoint sets `LIBP2P_LISTEN_ADDRS`
  to the container IP.
- **`rlnEnable` must precede `mixSetNodeInfo`** (the mix reads the spam-protection factory at
  mount). The gifter service (`rlnGifterServe`) is mounted after `start`, and clients call
  `rlnGifterRequest` only after relay1's service is up — `orchestrate.sh` orders all of this.
- **Clients open the wallet read-only.** A client loads and syncs the wallet module because
  the RLN module resolves accounts and reads the Merkle tree through it — but the client
  never calls `register_member`, so it never funds or signs a transaction. Only the gifter
  (`relay1`) spends RLNTOK.
- Use `logoscore call` for lifecycle calls, not one-shot `-c "..."` / `--quit-on-finish`
  (the one-shot client doesn't await async calls and reports a spurious `Timeout waiting
  for …`).

### GitHub handle

@adklempner

### Discord handle

@arseniy

### Existing docs or specs

- [LIP-158 — RLN Membership Allocation](https://lip.logos.co/anoncomms/raw/rln-membership-service.html)
  (the gifted-registration protocol this sim demonstrates)
- [LIP-144 — RLN DoS Protection for Mixnet](https://lip.logos.co/anoncomms/raw/mix-spam-protection-rln.html)
  (the per-hop mix RLN this sim exercises)
- In-repo after cloning: `docker/testnet/mix_e2e/QUICKSTART.md` (quickstart),
  `docker/testnet/mix_e2e/REPRODUCE.md` (full runbook + troubleshooting),
  `docker/testnet/mix_e2e/MIX_E2E.md` (topology, per-hop RLN, allocation mechanics),
  `docker/testnet/deployments/README.md` (deployment profiles: provision / verify).

### Hardware requirements

~30 GB disk (the image is ~17 GB; a cold Nix build needs headroom).

### Estimated time to complete

~30-45 min first run. Image build dominates; PHASE=2 is ~15 min for the 5 sequential on-chain
registrations (1 self + 4 gifted).

### Security notes

The gifter is a **membership provider / gatekeeper**, and the LIP-158 trade-offs apply:

- **Centralization / censorship.** The provider decides which identity commitments get
  registered and under what authentication policy. It can refuse or stall any request. In
  this sim that authority is a single node (`relay1`).
- **Sybil resistance rests entirely on the authentication layer.** LIP-158 auth is
  "pluggable"; this sim uses the spec's explicitly-allowed *demo/testnet* mode — a static
  EIP-191 allowlist (`fixtures/gifter_auth/`), one membership per allowlisted address. There
  is no protocol-level cap on how many memberships a provider may hand a single authenticated
  party; strength comes only from the auth policy chosen. The demo keys are not for
  production.
- **Fund custody + metadata.** The provider holds the funds that pay for every registration
  and learns which identity commitment maps to which authenticated identity. It never sees
  the client's RLN secret key (the client generates its identity locally and sends only the
  commitment), so it cannot forge the client's proofs.
- **IP↔identity correlation is out of scope.** LIP-158 defers the privacy concern of
  correlating a client's network address with its RLN identity to future work
  (RLN Stealth Commitments); this sim does not address it.
- **Slashing is the in-band enforcement.** Spam protection itself (LIP-144) is not provider-
  mediated: a member that exceeds `userMessageLimit` per epoch reuses a nullifier, which lets
  any relay reconstruct its secret key from the two Shamir shares and remove it from the
  group. Honest single-rate traffic stays anonymous.
