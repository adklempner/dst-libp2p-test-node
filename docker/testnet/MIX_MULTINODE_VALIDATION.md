# Step 4b — multi-node mix dial validation (in-process cbind layer)

## What this validates

The JSON-blob mix dial methods (Step 4a — `mixDial`, `mixDialWithReply`,
`mixRegisterDestReadBehavior`, `mixNodepoolAdd`) ride on the nim-libp2p-mix
Sphinx routing path. This step validates that **multi-node mix dial-with-reply
routing works in-process**, at the cbind layer, against the pinned
`nim-libp2p-mix` (`feat/mix-cbind`).

## Topology reality (why "2-node" is impossible)

Sphinx `PathLength = 3` is a compile-time constant (`nim-libp2p-mix/libp2p_mix/
sphinx.nim:9`), and the default build has exit ≠ destination. A forward mix dial
therefore needs **≥ 3 mix relays in the sender's pool excluding the destination**,
i.e. a **minimum of 5 distinct nodes**: sender S → M1 → M2 → M3(exit) → dest D.
The SURB reply reuses 3 relays with the sender as the final return hop.

## The routing test (mix.c)

`nim-libp2p-mix/cbind/examples/mix.c` is a 5-node in-process harness that:
1. starts 5 libp2p nodes with `mount_mix=1`,
2. gives each a curve25519 mix keypair + `set_node_info`,
3. registers a `DestReadBehavior` for `/ipfs/ping/1.0.0` on each,
4. fully meshes every node's mix nodepool,
5. `mix_dial_with_reply` from node 0 → node 4, writes 32 bytes, and reads the
   SURB reply back.

Success = the reply round-trips ("Read 32 bytes", exit 0). Run via the cbind
build + `g++ -I. -o mix examples/mix.c <libp2p static/shared> -pthread` (see
`cbind/cbind.nimble` `examples` task), or `nix build .#cbind` then link.

## RLN gen/verify + negatives — why NOT through in-process cbind-rln

The cbind-rln keeps a **single process-global `groupManager` pointer**
(`mix-rln-spam-protection-plugin/src/mix_rln_spam_protection/cbind.nim:60`),
overwritten by each node's `spamFactory` at mix mount (`cbind.nim:262`). In a
single process only the last-mounted node's GM is addressable via
`set_identity` / `set_cached_proof`, so distinct per-node RLN identities (the
sender generating a proof that relays verify) cannot be set up in one process
without a per-ctx GM refactor of the cbind.

Therefore RLN proof gen/verify + negative cases are validated at the layers
where each GM is directly addressable:
- **Proof gen/verify (positive):** the live single-node testnet readiness path
  (`single_node_readiness.sh`) — a real membership + cached merkle proof drives
  `generateProof`'s readiness, reaching `rlnIsReady==true`.
- **Negatives:** the plugin unit tests
  (`mix-rln-spam-protection-plugin/tests/test_all.nim`) — duplicate-nullifier
  detection and spam (same nullifier, different shares → slashing) rejection,
  plus epoch-validity bounds. A receiving mix hop rejects a message when
  `spam_protection.verifyProof` returns `ok(false)` (bad epoch gap, invalid
  merkle root once roots are tracked, bad zkSNARK, or duplicate/spam nullifier
  — `spam_protection.nim:577-668`).

## Follow-up for a true multi-node RLN-through-mix E2E

Either (a) refactor the cbind-rln to hold a per-ctx GM (keyed by libp2p ctx)
instead of one global, enabling distinct in-process identities; or (b) run a
5× logoscore-daemon testnet deployment (sender registers on-chain; relays +
dest verify). Both are larger efforts tracked separately.
