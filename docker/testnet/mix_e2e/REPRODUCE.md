# Reproduce: clone → run the RLN-over-mix sim (any dev)

Runs 5 `logoscore` daemons (sender + 3 relays + dest) as a docker-compose stack
and dials an RLN-protected message through a 3-hop mix to the dest, on the hosted
LEZ testnet, using the new universal `logos-libp2p-module` stack.

## Requirements (that's all)
- **Docker** running, ~30 GB free in its VM.
- **git**, and internet access (GitHub + nix caches + `https://testnet.lez.logos.co/`).
- No SSH keys, no manual fixtures, no local toolchain — logoscore, the wallet/rln
  modules, and the testnet keystores are all fetched/built by the steps below.
- Linux or macOS host (the scripts are bash-3.2 compatible).

## Quick start (one bootstrap)
```sh
git clone git@github.com:adklempner/dst-libp2p-test-node.git
cd dst-libp2p-test-node
bash docker/testnet/mix_e2e/bootstrap.sh        # clones 3 sibling repos (SSH) + builds .lgx + base image
cd docker/testnet/mix_e2e
PHASE=2 bash orchestrate.sh                      # full 3-hop RLN-over-mix delivery
docker compose down                             # tear down
```
`bootstrap.sh` clones `logos-libp2p-module`, `mix-rln-spam-protection-plugin`,
and `nim-libp2p-mix` (the right branches) as siblings of this repo, builds the
Linux libp2p `.lgx`, and builds the base image tagged `lp2p-mix-e2e`. First run
is ~30-45 min (image build dominates); re-runs are fast.

The forks are public, so if you don't have SSH keys, override with HTTPS:
`REPO_BASE=https://github.com/adklempner bash docker/testnet/mix_e2e/bootstrap.sh`.

## What bootstrap does (run manually if you prefer)
```sh
# 1. clone the four repos as siblings (same parent dir; SSH — or swap to https:// URLs)
mkdir logos && cd logos
git clone -b feat/logos-core-integration git@github.com:adklempner/dst-libp2p-test-node.git
git clone -b feat/enable-mix             git@github.com:adklempner/logos-libp2p-module.git
git clone -b feat/cbind-rln             git@github.com:adklempner/mix-rln-spam-protection-plugin.git
git clone -b feat/mix-cbind             git@github.com:adklempner/nim-libp2p-mix.git

# 2. build the Linux libp2p .lgx (rsyncs the 3 sibling repos)
cd dst-libp2p-test-node
LOGOS_ROOT="$(cd .. && pwd)" bash docker/build_lgx_linux.sh   # -> docker/lp2p-out/libp2p_module.lgx

# 3. build the base image (logoscore + wallet/rln .lgx bundles + testnet fixtures)
docker build -f docker/Dockerfile.testnet-e2e -t lp2p-mix-e2e .
```

## Run the sim
By default src and dest exchange `MSG_COUNT` (default 3) request/reply round-trips
**each way** over the mix (RLN enforced on both legs in PHASE=2).
```sh
cd docker/testnet/mix_e2e
PHASE=1 bash orchestrate.sh                 # request/reply routing through our module (RLN off, fast)
PHASE=2 bash orchestrate.sh                 # full per-hop RLN, N round-trips each way (~15 min: 5 registrations)
MSG_COUNT=10 PHASE=2 bash orchestrate.sh    # more messages
BIDIR=0 PHASE=2 bash orchestrate.sh         # sender->dest only
PHASE=2 NEG=1 bash orchestrate.sh           # negative: unregistered sender rejected (0 replies)
docker compose down
```
Knobs: `MSG_COUNT` (round-trips/initiator, default 3), `BIDIR` (1=both directions,
default), `MSG_PROTO`/`READ_SIZE` (default `/ipfs/ping`/32), `MSG_INTERVAL`.
Single-node RLN readiness alone is the image default: `docker run --rm lp2p-mix-e2e`.

Expected PHASE=2 output: 5 distinct on-chain leaves (all `rlnIsReady=True`);
`sender->dest: N/N` and `dest->sender: N/N` replies received; per-node
`Generated RLN proof successfully`; all 3 relays `Proof verified
successfully`; exit `Dial successful` → dest `Accepted an incoming connection`.

See `MIX_E2E.md` for topology, the per-hop RLN design, and the multi-identity
registration mechanics.

## Notes
- Each `PHASE=2` run registers 5 fresh random identities, so leaves accumulate on
  the shared testnet tree across runs. Pin the seeds in `orchestrate.sh` for
  idempotent re-runs.
- Changed a source repo? Re-run step 2; the compose entrypoint reinstalls the
  rebuilt `.lgx` over the image's baked copy.
- Verified end to end from a from-scratch image build (wallet/rln/libp2p all load;
  PHASE=1 green) — no hand-fixing required.

## Troubleshooting registration failures

The 5 registrations are funded by a shared on-chain **payment account** and write
into a single **RLN tree**, both provisioned by `logos-lez-rln`'s `run_setup`.
Two real-world failure modes — `orchestrate.sh` **auto-detects both** (it scans
the node logs and prints the exact fix), but here's the playbook.

Set `LEZ_RLN_DIR=/path/to/logos-lez-rln` so the auto-suggestions print real paths.

### A) Payment account out of funds
Symptom (auto-detected): registration never confirms; node log shows
`Insufficient balance`. Each register costs `price_per_unit * rate` RLNTOK, so a
funded account is finite.

Fix — mint a fresh funded payment account (there is no top-up CLI; `run_setup`
re-run draws a new funded account from the master supply), then re-run pointing
`HOLDING_ACCT` at it (no image rebuild needed):
```sh
cd "$LEZ_RLN_DIR/lez-rln" && source ../testnet/env.sh && cargo run --bin run_setup
HOLDING_ACCT=$(cat ~/.logos-lez-rln/payment_account_*.txt) PHASE=2 bash orchestrate.sh
```
If the log instead says `supply holding may be out of funds`, the master supply
is exhausted → do the full re-deploy in (B).

### B) Tree full / fresh tree (bump treeId)
Symptom (auto-detected): node log shows `Would exceed max total rate limit` (the
rate-limit pool, ~10k members at rate 100, is the practical cap). `treeId` is a
**compiled-in constant** (the `LEZ_RLN_TREE_ID_HEX` env is NOT read by the Rust
binaries), so a fresh tree means edit + rebuild + re-deploy:
```sh
# 1. edit TREE_ID (new 32 bytes) in:
#      $LEZ_RLN_DIR/lez-rln/src/rln/client.rs   (the TREE_ID constant)
cd "$LEZ_RLN_DIR/lez-rln" && cargo build --bin run_setup --bin register_member
# 2. wipe caches for the old tree
rm -f ../testnet/storage.json ../testnet/supply_holding.txt \
      ~/.logos-lez-rln/supply_holding_*.txt ~/.logos-lez-rln/payment_account_*.txt
# 3. fresh deploy on the new tree_id (mints supply + a funded payment account)
source ../testnet/env.sh && cargo run --bin run_setup
# 4. refresh the fixtures baked into the image, then rebuild it:
#      $LEZ_RLN_DIR/testnet/{config_account.txt, payment_account.txt,
#                            supply_holding.txt, storage.json.seed}
cd "$REPO"/dst-libp2p-test-node
docker build -f docker/Dockerfile.testnet-e2e -t lp2p-mix-e2e .
```
(The image clones `logos-lez-rln` itself, so rebuilding the image after the
fixtures land in the repo's testnet dir is what propagates the new tree.)

### Account overrides (recover without rebuilding)
`orchestrate.sh` reads the funder/config from the baked fixtures by default but
honors overrides — point at a freshly-funded account or a different tree:
```sh
HOLDING_ACCT=<funded payment acct> CONFIG_ACCT=<config acct for the tree> PHASE=2 bash orchestrate.sh
```
