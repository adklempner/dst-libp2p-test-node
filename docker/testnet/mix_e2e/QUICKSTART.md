# RLN-over-mix sim — quickstart

Run 5 `logoscore` nodes as a docker-compose stack and watch **every node obtain an
RLN membership through gifted on-chain registration** on the hosted LEZ testnet:
`relay1` (the gifter) holds the only funded wallet and registers the other four
nodes' identities on their behalf after an **EIP-191** auth handshake — they never
fund or sign a transaction. The gifted memberships are then exercised over a 3-hop
Sphinx mix (RLN verified + regenerated at each hop, both legs), using the universal
`logos-libp2p-module` stack.

## Requirements
- **Docker** running, ~30 GB free in its VM (the image is ~17 GB; a cold nix
  build needs headroom)
- **git** + internet (GitHub, nix caches, `https://testnet.lez.logos.co/`)
- Linux or macOS. No manual keystores, no local toolchain — the build
  fetches/builds logoscore, the wallet/rln modules, and bakes the **deployment
  profile** (RLN tree + wallet) for you. SSH keys optional (clone over HTTPS if
  you don't have them).

## What gets cloned
`bootstrap.sh` clones four sibling repos next to `dst-libp2p-test-node` (from the
`adklempner` fork, SSH by default):

| repo | branch | role |
|---|---|---|
| `logos-libp2p-module` | `feat/enable-mix` | universal libp2p module (mix + RLN + gifter glue) |
| `mix-rln-spam-protection-plugin` | `feat/cbind-rln` | RLN SpamProtection (LIP-144) |
| `nim-libp2p-mix` | `feat/mix-cbind` | Sphinx mix (LIP-99) |
| `logos-rln-gifter` | `master` | RLN membership gifter protocol (LIP-158) |

The image build additionally clones `logos-co/logos-lez-rln` @
`feat/rln-stateless-v2.0.2` internally, then overlays this repo's vendored
`docker/vendor/{lssa,lez-rln-ffi,logos-rln-module}` — no action needed.

## Quick start
```sh
git clone git@github.com:adklempner/dst-libp2p-test-node.git   # or https://github.com/adklempner/dst-libp2p-test-node.git
cd dst-libp2p-test-node
bash docker/testnet/mix_e2e/bootstrap.sh     # clone 3 siblings (SSH) + build .lgx + image (~30-45 min; longer if the nix cache is cold)
cd docker/testnet/mix_e2e
PHASE=2 bash orchestrate.sh                   # src<->dest exchange 3 round-trips each way, RLN-enforced (~10-15 min)
docker compose down                          # tear down when done
```
No SSH key? Clone + bootstrap over HTTPS:
```sh
git clone https://github.com/adklempner/dst-libp2p-test-node.git
REPO_BASE=https://github.com/adklempner bash docker/testnet/mix_e2e/bootstrap.sh
```
Re-runs of `bootstrap.sh` are fast (siblings already cloned, layers cached). By
default src and dest **message each other**: `MSG_COUNT` (default 3)
request/reply round-trips each way over the mix, RLN-verified on both legs.
Other modes / knobs:
```sh
PHASE=1 bash orchestrate.sh                # mix request/reply routing only (RLN off, fast — good first smoke)
MSG_COUNT=10 PHASE=2 bash orchestrate.sh   # more messages per direction
BIDIR=0 PHASE=2 bash orchestrate.sh        # sender->dest only (not bidirectional)
PHASE=2 NEG=1 bash orchestrate.sh          # negative: sender never asks the gifter -> REJECTED (0 replies)
PHASE=2 NEG=2 bash orchestrate.sh          # negative: sender asks with a NON-allowlisted key -> gifter refuses
```

## Which deployment (RLN tree) it runs against
The image bakes a **deployment profile** — one on-chain RLN instance captured by
`docker/testnet/deployments/<name>/{deployment.json, storage.json}`. The default
is **`shared-5ade`** (a shared testnet tree). Select another provisioned
deployment with `docker build --build-arg DEPLOYMENT=<name> ...`, or provision a
new one (below). See `docker/testnet/deployments/README.md`.

## What success looks like (PHASE=2)
- **Gifted allocation (the headline):** 5 distinct on-chain leaves (1 self + 4 gifted),
  `leaf_opt==leaf_actual` + `confirmed=true` + `rlnIsReady=True` on every node;
  `relay1 gifter service mounted`; relay1's log shows `handling RLN gifter request`
  + `RLN gifter registration succeeded` x4; each client logs `RLN membership granted`
- `sender->dest: 3/3 replies received` and `dest->sender: 3/3 replies received`
- per-node `Generated RLN proof successfully` + relays `Proof verified successfully`
  on both the forward and SURB-reply legs; `VERDICT: PASS`

## If registration fails
All registrations (relay1's own + the 4 gifted ones) are funded by the deployment's
payment account — held only by the gifter (`relay1`) — and write into its RLN tree.
The harness **auto-detects** the two common failures (scanning relay1's log) and
prints the exact fix — set `LEZ_RLN_DIR=/path/to/logos-lez-rln` so the printed
commands show real paths. Both fixes **provision a fresh deployment and rebuild the
image against it** (the gifter signs with the *baked* wallet, so a new payment
account / tree must be baked in). First build the host binaries:
```sh
(cd "$LEZ_RLN_DIR/lez-rln" && PYO3_PYTHON=$(command -v python3) cargo build --release --bin run_setup --bin derive_accounts)
```
- **Out of funds** (log shows `Insufficient balance`): re-provision on the **same
  tree** — `run_setup` mints a fresh funded payment account:
  ```sh
  D=docker/testnet/deployments/shared-5ade
  LEZ_RLN_DIR=/path/to/logos-lez-rln bash docker/testnet/provision.sh \
    --name shared-refunded --tree $(jq -r .tree_id "$D/deployment.json") --adopt-wallet "$D/storage.json"
  docker build -f docker/Dockerfile.testnet-e2e --build-arg DEPLOYMENT=shared-refunded -t lp2p-mix-e2e .
  ```
- **Tree full** (log shows `Would exceed max total rate limit`): provision a
  **brand-new tree** — `tree_id` is the single knob, **no source edits**:
  ```sh
  LEZ_RLN_DIR=/path/to/logos-lez-rln bash docker/testnet/provision.sh --name fresh-tree
  docker build -f docker/Dockerfile.testnet-e2e --build-arg DEPLOYMENT=fresh-tree -t lp2p-mix-e2e .
  ```

> A host `logos-lez-rln` checkout also needs a plain `lssa/` sibling clone at rev
> `v0.2.0-rc6` (the flake fetches it for nix builds, but host cargo builds read it
> from disk). See `docker/testnet/deployments/README.md`.

## More detail (in the repo after cloning)
- `docker/testnet/deployments/README.md` — deployment profiles (run-against-existing / redeploy-fresh, `provision.sh`/`verify.sh`)
- `docker/testnet/mix_e2e/REPRODUCE.md` — full runbook + troubleshooting
- `docker/testnet/mix_e2e/MIX_E2E.md` — topology, per-hop RLN design, registration mechanics
