# 5-node RLN-over-mix E2E (new universal logos-libp2p-module stack)

Full end-to-end: a logos-core **sender** generates an RLN proof and dials through
a 3-hop Sphinx mix path; the proof is **verified and regenerated at every hop**;
the exit delivers to the **dest** — all via real `logoscore` daemons on the
hosted LEZ testnet, on the **new universal `logos-libp2p-module` + cbind-rln**
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

## Run

```sh
# RLN off — proves Sphinx request/reply routing + mesh through our module:
PHASE=1 bash orchestrate.sh
# RLN on — full per-hop RLN, 5 distinct registrations + N round-trips each way:
PHASE=2 bash orchestrate.sh
# more messages / one-directional / spaced out:
MSG_COUNT=10 PHASE=2 bash orchestrate.sh
BIDIR=0 PHASE=2 bash orchestrate.sh            # sender->dest only
# negative: an unregistered sender's round-trips are rejected (0 replies):
PHASE=2 NEG=1 bash orchestrate.sh
```

Knobs: `MSG_COUNT` (round-trips per initiator, default 3), `BIDIR` (1=both
src↔dest initiate, default; 0=sender→dest only), `MSG_PROTO`/`READ_SIZE`
(default `/ipfs/ping`/32), `MSG_INTERVAL` (sleep between, default 0). Keep
`MSG_COUNT` ≲ ~100 (per-epoch RLN rate limit).

Image `lp2p-mix-e2e` = `docker commit` of the working single-node `tn` container
(the raw `lp2p-testnet-e2e` image ships wallet/rln with an absolute nix-store path
in the `.so` NEEDED that isn't present → unloadable). Rebuild the libp2p `.lgx`
first with `docker/build_lgx_linux.sh`; the entrypoint overlays it.

## What each piece does

- `docker-compose.yml` — 5 services (sender + relay1/2/3 + dest), `LIBP2P_LISTEN_ADDRS=/ip4/0.0.0.0/tcp/9000`.
- `entrypoint.sh` — install the freshly-built `libp2p_module.lgx`, run the daemon.
- `keys.py` — dependency-free host-side keys: curve25519 mix pubkey (RFC7748
  X25519, matches nim `public(priv)`) + secp256k1 libp2p pubkey decoded from the
  peerId (libp2p inlines it). Byte-returning RPCs are UTF-8-corrupted over `--json`,
  so keys are derived host-side.
- `orchestrate.sh` (bash 3.2) — bring up; on every node load wallet→rln→libp2p
  (dependency chain), `mixSetNodeInfo`, mesh the pool via `mixNodepoolAdd`; in
  PHASE 2 register each node (distinct seed, one funded payment account, with
  on-chain confirmation barrier + retry); register `mixRegisterDestReadBehavior`
  on all nodes (the SURB exit is random); then run `MSG_COUNT` request/reply
  round-trips per direction (`mixDialWithReply`→`streamWrite`→`streamReadExactly`).

## Multi-identity registration (the tricky part)

`generate_identity(seed)` is a pure function of 32 bytes; `register_member` uses
the holding account only as funder/signer (identity = idCommitment, separate). So
**one funded payment account registers all 5 distinct identities** —
`rlnRegister` takes an optional `seed` to decouple seed from funder.

Registrations are **serialized with an on-chain confirmation barrier**: after each
`rlnRegister`, poll `liblogos_rln_module is_member_registered(config, idCommitment)`
until `registered:true` before the next node registers. Without this, all nodes
sync to the same block and register the same optimistic leaf → collision (the
`rlnIsReady` barrier is NOT reliable: `get_merkle_proofs` returns a proof for the
optimistic leaf before the tree canonically advances).

## Expected output (PHASE=2, MSG_COUNT=3)

- 5 distinct `leaf_actual` values, `leaf_opt==leaf_actual`, all `rlnIsReady=True`.
- `sender->dest: 3/3 replies received` and `dest->sender: 3/3 replies received`.
- per-node RLN counts (`generated`/`verified`) > 0 on both legs; total
  verifications ≈ `6 * MSG_COUNT * directions` (e.g. ~36 for 3×2).
- `VERDICT: PASS`.

Note: the reply bytes are UTF-8-corrupted over `--json`, so a "reply received" =
`streamReadExactly` returned ok (the SURB round-trip completed), not a byte
compare. The log-side `Proof verified` counts corroborate per-hop RLN.

## Key fixes that made this work (committed)

- `logos-libp2p-module`: `LIBP2P_LISTEN_ADDRS` env (reachable across containers);
  JSON-blob mix dial methods; `rlnRegister` seed/funder decoupling; in-module
  proof-refresh QTimer.
- `mix-rln-spam-protection-plugin`: autostart the **SpamProtection** (`sp.start`
  → `state=Ready`), not just the GM — both generateProof and verifyProof gate on
  `state==Ready` (single-node never caught this); cross-thread lock on the GM.
