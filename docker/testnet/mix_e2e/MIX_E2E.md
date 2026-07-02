# 5-node RLN-over-mix E2E (new universal logos-libp2p-module stack)

Full end-to-end, headlined by **gifted RLN membership allocation**: `relay1` (the
**gifter**) is the only node holding a funded wallet — it self-registers, then
serves `/logos/rln/membership/1.0.0` (LIP-158) so the other four nodes
**authenticate with an EIP-191 signature and receive a distinct on-chain RLN
membership without funding or signing any transaction themselves**. The gifted
memberships are then exercised over a 3-hop Sphinx mix: a **sender** generates an
RLN proof and dials through the mix; the proof is **verified and regenerated at
every hop**; the exit delivers to the **dest** — all via real `logoscore` daemons
on the hosted LEZ testnet, on the **universal `logos-libp2p-module` + cbind-rln**
stack (not the legacy delivery_module).

By default src and dest **message each other**: each does `MSG_COUNT` (default 3)
**request/reply round-trips** over the mix (`mixDialWithReply` + SURB return
path). Each round-trip = a request (initiator→peer, /ipfs/ping echoes it) + a
reply back via SURB — and **RLN is enforced on BOTH legs** (≈6 verifications per
round-trip: 3 forward + 3 reply).

## Topology

5 daemons, one per container, on a shared docker bridge net. Each node listens on
its **own container IP**:9000 (the entrypoint detects it) — NOT `0.0.0.0`, which
would advertise `127.0.0.1` too and make the mix route some next-hop/SURB-reply
dials to loopback (Noise peer-id mismatch → dropped):

```
sender ──Sphinx──▶ relay(hop1) ──▶ relay(hop2) ──▶ relay(hop3/exit) ──▶ dest
        generate        verify+regen    verify+regen     verify          deliver
```

Sphinx `PathLength=3` (hardcoded), exit≠dest ⇒ minimum **5 nodes**. This mix-rln
does **per-hop RLN**: each hop verifies the incoming proof AND regenerates one for
the next hop, so **every mix node is a registered RLN member** (distinct leaf).
`relay1` doubles as the **gifter** (membership provider): it is the only node with
a funded wallet, and it registers the other four nodes' memberships on their behalf
(next section).

## Run

```sh
# RLN off — proves Sphinx request/reply routing + mesh through our module:
PHASE=1 bash orchestrate.sh
# RLN on — gifter allocates 5 memberships (1 self + 4 gifted) + N round-trips each way:
PHASE=2 bash orchestrate.sh
# more messages / one-directional / spaced out:
MSG_COUNT=10 PHASE=2 bash orchestrate.sh
BIDIR=0 PHASE=2 bash orchestrate.sh            # sender->dest only
# negative: sender never asks the gifter -> unregistered -> rejected (0 replies):
PHASE=2 NEG=1 bash orchestrate.sh
# negative: sender asks with a NON-allowlisted key -> gifter refuses auth -> rejected:
PHASE=2 NEG=2 bash orchestrate.sh
```

Knobs: `MSG_COUNT` (round-trips per initiator, default 3), `BIDIR` (1=both
src↔dest initiate, default; 0=sender→dest only), `MSG_PROTO`/`READ_SIZE`
(default `/ipfs/ping`/32), `MSG_INTERVAL` (sleep between, default 0). Keep
`MSG_COUNT` ≲ ~100 (per-epoch RLN rate limit).

Image `lp2p-mix-e2e` is built by `docker/Dockerfile.testnet-e2e` (bootstrap step 3):
logoscore + the wallet/rln `.lgx` bundles + the baked **deployment profile**
(`/testnet`, staged at build time from `docker/testnet/deployments/<DEPLOYMENT>`,
default `shared-5ade`). Build the libp2p `.lgx` first with
`docker/build_lgx_linux.sh`; the compose `entrypoint.sh` overlays the freshly-built
`.lgx` over the image's baked copy at container start.

## What each piece does

- `docker-compose.yml` — 5 services (sender + relay1/2/3 + dest), `LIBP2P_LISTEN_ADDRS=/ip4/0.0.0.0/tcp/9000`.
- `entrypoint.sh` — install the freshly-built `libp2p_module.lgx`, run the daemon.
- `keys.py` — dependency-free host-side keys: curve25519 mix pubkey (RFC7748
  X25519, matches nim `public(priv)`) + secp256k1 libp2p pubkey decoded from the
  peerId (libp2p inlines it). Byte-returning RPCs are UTF-8-corrupted over `--json`,
  so keys are derived host-side.
- `fixtures/gifter_auth/` — demo EIP-191 keys + the gifter allowlist (NOT for
  production). Sourced host-side; the keys never enter the image.
- `orchestrate.sh` (bash 3.2) — bring up; on every node load wallet→rln→libp2p
  (dependency chain), `mixSetNodeInfo`, mesh the pool via `mixNodepoolAdd`; in
  PHASE 2 relay1 self-allocates + serves the gifter (`rlnGifterServe`) and the
  other 4 nodes obtain gifted memberships (`rlnGifterRequest`), each with the
  on-chain confirmation barrier + retry; register `mixRegisterDestReadBehavior`
  on all nodes (the SURB exit is random); then run `MSG_COUNT` request/reply
  round-trips per direction (`mixDialWithReply`→`streamWrite`→`streamReadExactly`).

## Gifted membership allocation (the headline)

Registration is **funder≠identity**: `generate_identity(seed)` is a pure function
of 32 bytes and `register_member(config, wallet, idCommitment, rate)` uses `wallet`
only as tx funder/signer. That decoupling is what lets a **gifter** register someone
else's identity: the client derives its own identity locally and sends only the
`idCommitment` (its RLN secret never leaves the node); the gifter funds and signs the
on-chain registration and returns the leaf.

Flow (`orchestrate.sh`, PHASE=2):
1. **relay1 (gifter)** opens its funded wallet, self-allocates its own membership via
   `rlnRegister` + the confirmation barrier, then mounts the service:
   `rlnGifterServe {config, wallet, allowlist}` → serves `/logos/rln/membership/1.0.0`.
2. **relay2/relay3/dest/sender (clients)** each call
   `rlnGifterRequest {gifterPeerId, gifterMultiaddr, config, seed, authKey}`. The module
   generates the identity locally, signs an **EIP-191** message over the idCommitment with
   the client's key, dials relay1, and (on success) adopts the granted leaf
   (`rlnSetIdentity` + proof refresh). The gifter authenticates the signature against its
   allowlist (one membership per allowlisted address), calls `register_member` funded by its
   own wallet, and returns `{leaf_index, config_account}`.
3. EIP-191 auth (`fixtures/gifter_auth/`) is used **only** for the client↔gifter handshake.
   The RLN spam-protection plugin is unchanged — it still generates/verifies proofs from
   whatever identity the node holds; only *how the node got that identity* changed.

Allocations are **serialized with an on-chain confirmation barrier**: after each membership,
poll `liblogos_rln_module is_member_registered(config, idCommitment)` until `registered:true`
before the next client requests — so the single gifter wallet's txs stay nonce-ordered and
each membership lands on a **distinct leaf**. Without this, requests would race the leaf
counter and collide (the `rlnIsReady` barrier alone is NOT reliable: `get_merkle_proofs`
returns a proof for the optimistic leaf before the tree canonically advances). Because a
cross-module QtRO call deadlocks on the libp2p thread (like the RLN fetcher), the gifter's
request handler enqueues the job and a Qt-thread drain runs `register_member` and completes
the response asynchronously.

## Expected output (PHASE=2, MSG_COUNT=3)

- 5 distinct `leaf_actual` values (1 self + 4 gifted), `leaf_opt==leaf_actual`,
  all `rlnIsReady=True`; `relay1 gifter service mounted`.
- relay1's log: `handling RLN gifter request` + `RLN gifter registration succeeded`
  x4; each client's log: `RLN membership granted`; observe line
  `gifter(relay1): 'RLN gifter registration succeeded' x4`.
- `sender->dest: 3/3 replies received` and `dest->sender: 3/3 replies received`.
- per-node RLN counts (`generated`/`verified`) > 0 on both legs; total
  verifications ≈ `6 * MSG_COUNT * directions` (e.g. ~36 for 3×2).
- `VERDICT: PASS`.

Note: the reply bytes are UTF-8-corrupted over `--json`, so a "reply received" =
`streamReadExactly` returned ok (the SURB round-trip completed), not a byte
compare. The log-side `Proof verified` counts corroborate per-hop RLN.

## Key fixes that made this work

- `logos-rln-gifter` (new): standalone nim-libp2p `LPProtocol` for
  `/logos/rln/membership/1.0.0` (LIP-158) + EIP-191 allowlist auth, superset-linked
  into the combined `.lgx`. The register bridge enqueues to the host and completes
  asynchronously (`libp2p_gifter_complete`) so no cross-module call runs on the
  libp2p thread.
- `logos-libp2p-module`: `rlnGifterServe`/`rlnGifterRequest` glue (client signs
  EIP-191 + adopts the gifted leaf; server drains its register queue on the Qt
  thread); plus `LIBP2P_LISTEN_ADDRS` env (reachable across containers), JSON-blob
  mix dial methods, `rlnRegister` seed/funder decoupling, in-module proof-refresh
  QTimer.
- `mix-rln-spam-protection-plugin` (unchanged by the gifter work): autostart the
  **SpamProtection** (`sp.start` → `state=Ready`), not just the GM — both
  generateProof and verifyProof gate on `state==Ready` (single-node never caught
  this); cross-thread lock on the GM.
