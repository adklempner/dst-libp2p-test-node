# Reproduce: clone → run the gifted-RLN-over-mix sim (any dev)

Runs 5 `logoscore` daemons as a docker-compose stack. Every node obtains an RLN
membership through **gifted on-chain registration** (LIP-158): `relay1` (the gifter)
holds the only funded wallet and registers the other four nodes' identities on their
behalf after an EIP-191 auth handshake. The gifted memberships are then exercised by
dialing an RLN-protected message through a 3-hop mix to the dest, on the hosted LEZ
testnet, using the universal `logos-libp2p-module` stack.

## Requirements (that's all)
- **Docker** running, ~30 GB free in its VM.
- **git**, and internet access (GitHub + nix caches + `https://testnet.lez.logos.co/`).
- No manual keystores, no local toolchain — logoscore, the wallet/rln modules, the
  gifter protocol, and the deployment profile (RLN tree + wallet) are all
  fetched/built/baked by the steps below. Only the gifter needs the funded wallet;
  the other nodes fund/sign nothing. SSH keys optional (clone over HTTPS).
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
`nim-libp2p-mix`, and `logos-rln-gifter` (the right branches) as siblings of this
repo, builds the Linux libp2p `.lgx` (mix + RLN + gifter), and builds the base image
tagged `lp2p-mix-e2e`. First run is ~30-45 min (image build dominates); re-runs fast.

The forks are public, so if you don't have SSH keys, override with HTTPS:
`REPO_BASE=https://github.com/adklempner bash docker/testnet/mix_e2e/bootstrap.sh`.

## What bootstrap does (run manually if you prefer)
```sh
# 1. clone the five repos as siblings (same parent dir; SSH — or swap to https:// URLs)
mkdir logos && cd logos
git clone -b feat/logos-core-integration git@github.com:adklempner/dst-libp2p-test-node.git
git clone -b feat/enable-mix             git@github.com:adklempner/logos-libp2p-module.git
git clone -b feat/cbind-rln             git@github.com:adklempner/mix-rln-spam-protection-plugin.git
git clone -b feat/mix-cbind             git@github.com:adklempner/nim-libp2p-mix.git
git clone -b master                     git@github.com:adklempner/logos-rln-gifter.git

# 2. build the Linux libp2p .lgx (rsyncs the 4 sibling repos: mix + RLN + gifter)
cd dst-libp2p-test-node
LOGOS_ROOT="$(cd .. && pwd)" bash docker/build_lgx_linux.sh   # -> docker/lp2p-out/libp2p_module.lgx

# 3. build the base image (logoscore + wallet/rln .lgx bundles + the deployment
#    profile, staged into /testnet from docker/testnet/deployments/<DEPLOYMENT>)
docker build -f docker/Dockerfile.testnet-e2e -t lp2p-mix-e2e .
#    (pick a different provisioned deployment with --build-arg DEPLOYMENT=<name>)
```

## Run the sim
By default src and dest exchange `MSG_COUNT` (default 3) request/reply round-trips
**each way** over the mix (RLN enforced on both legs in PHASE=2).
```sh
cd docker/testnet/mix_e2e
PHASE=1 bash orchestrate.sh                 # request/reply routing through our module (RLN off, fast)
PHASE=2 bash orchestrate.sh                 # gifted per-hop RLN, N round-trips each way (~15 min: 5 registrations)
MSG_COUNT=10 PHASE=2 bash orchestrate.sh    # more messages
BIDIR=0 PHASE=2 bash orchestrate.sh         # sender->dest only
PHASE=2 NEG=1 bash orchestrate.sh           # negative: sender never asks the gifter -> rejected (0 replies)
PHASE=2 NEG=2 bash orchestrate.sh           # negative: sender's key not allowlisted -> gifter refuses auth
docker compose down
```
Knobs: `MSG_COUNT` (round-trips/initiator, default 3), `BIDIR` (1=both directions,
default), `MSG_PROTO`/`READ_SIZE` (default `/ipfs/ping`/32), `MSG_INTERVAL`.
Single-node RLN readiness alone (self-registration, no gifter) is the image default:
`docker run --rm lp2p-mix-e2e`.

Expected PHASE=2 output: 5 distinct on-chain leaves (1 self + 4 gifted, all
`rlnIsReady=True`); `relay1 gifter service mounted`; relay1's log shows
`RLN gifter registration succeeded` x4 and each client `RLN membership granted`;
`sender->dest: N/N` and `dest->sender: N/N` replies received; per-node
`Generated RLN proof successfully`; all 3 relays `Proof verified successfully`.

See `MIX_E2E.md` for topology, the per-hop RLN design, and the gifted-allocation
mechanics.

## Notes
- Each `PHASE=2` run allocates 5 fresh random identities (1 self + 4 gifted), so
  leaves accumulate on the shared testnet tree across runs.
- EIP-191 auth uses demo keys in `fixtures/gifter_auth/` (NOT for production); they
  are sourced host-side and never enter the image.
- Changed a source repo? Re-run step 2; the compose entrypoint reinstalls the
  rebuilt `.lgx` over the image's baked copy.

## Troubleshooting registration failures

All 5 registrations (the gifter's own + the 4 gifted) are funded by the deployment's
on-chain **payment account** — held only by the gifter (`relay1`) — and write into
its **RLN tree**, both captured by the deployment profile baked into the image
(`docker/testnet/deployments/<name>/{deployment.json, storage.json}`).
`orchestrate.sh` **auto-detects** the two real-world failure modes (it scans relay1's
log and prints the exact fix); here's the playbook.

Both fixes **provision a fresh deployment and rebuild the image against it** — the
gifter signs with the *baked* wallet, so a new payment account / tree has to be
baked in (there is no reliable no-rebuild override once the wallet changes). First
build the host binaries (needs a `logos-lez-rln` checkout — set `LEZ_RLN_DIR`):
```sh
(cd "$LEZ_RLN_DIR/lez-rln" && PYO3_PYTHON=$(command -v python3) \
    cargo build --release --bin run_setup --bin derive_accounts)
```
> A host `logos-lez-rln` checkout also needs a plain `lssa/` sibling clone at rev
> `v0.2.0-rc6` for the cargo build (the flake fetches it for nix builds, but host
> builds read it from disk). See `../deployments/README.md`.

### A) Payment account out of funds
Symptom (auto-detected): registration never confirms; node log shows
`Insufficient balance`. Each register costs `price_per_unit * rate` RLNTOK, so a
funded account is finite. Re-provision on the **same tree** — reusing the wallet,
`run_setup` mints a fresh funded payment account — then rebuild:
```sh
D=docker/testnet/deployments/shared-5ade
LEZ_RLN_DIR=/path/to/logos-lez-rln bash docker/testnet/provision.sh \
  --name shared-refunded --tree $(jq -r .tree_id "$D/deployment.json") --adopt-wallet "$D/storage.json"
docker build -f docker/Dockerfile.testnet-e2e --build-arg DEPLOYMENT=shared-refunded -t lp2p-mix-e2e .
```
If the log instead says `supply holding may be out of funds`, the master supply is
exhausted → provision a brand-new tree, as in (B).

### B) Tree full / fresh tree
Symptom (auto-detected): node log shows `Would exceed max total rate limit` (the
rate-limit pool, ~10k members at rate 100, is the practical cap). `tree_id` is the
single knob (env-driven, **no source edits**): provision a brand-new tree and
rebuild against it:
```sh
LEZ_RLN_DIR=/path/to/logos-lez-rln bash docker/testnet/provision.sh --name fresh-tree
docker build -f docker/Dockerfile.testnet-e2e --build-arg DEPLOYMENT=fresh-tree -t lp2p-mix-e2e .
```
`provision.sh` writes the new `deployments/fresh-tree/` (descriptor + wallet) into
this repo, and `--build-arg DEPLOYMENT=` bakes it in. See `../deployments/README.md`
for the full deployment-profile workflow (`provision.sh` / `verify.sh`).
