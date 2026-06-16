#!/usr/bin/env bash
# One-shot bootstrap for the RLN-over-mix sim, runnable by any dev with only
# Docker + git installed. Run it from a clone of dst-libp2p-test-node:
#
#   git clone git@github.com:adklempner/dst-libp2p-test-node.git
#   cd dst-libp2p-test-node
#   bash docker/testnet/mix_e2e/bootstrap.sh
#   cd docker/testnet/mix_e2e && PHASE=2 bash orchestrate.sh
#
# It clones the three sibling repos (next to this one), builds the Linux libp2p
# .lgx, and builds the base image tagged `lp2p-mix-e2e` (logoscore + wallet/rln
# modules + testnet fixtures — all fetched by the image build itself).
#
# Clones over SSH by default. The forks are public, so if you don't have SSH
# keys set up, override with HTTPS:
#   REPO_BASE=https://github.com/adklempner bash docker/testnet/mix_e2e/bootstrap.sh
set -euo pipefail

BASE="${REPO_BASE:-git@github.com:adklempner}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"          # dst-libp2p-test-node
SIBLINGS="$(cd "$REPO_ROOT/.." && pwd)"            # parent dir = sibling root

command -v docker >/dev/null || { echo "docker is required"; exit 1; }
command -v git    >/dev/null || { echo "git is required"; exit 1; }

clone(){ # repo branch
  if [ -d "$SIBLINGS/$1/.git" ]; then
    echo "  $1 already present"
  else
    echo "  cloning $1 ($2)"
    git clone --depth 1 -b "$2" "$BASE/$1.git" "$SIBLINGS/$1"
  fi
}

echo "=== 1/3 clone sibling repos into $SIBLINGS ==="
clone logos-libp2p-module             feat/enable-mix
clone mix-rln-spam-protection-plugin  feat/cbind-rln
clone nim-libp2p-mix                  feat/mix-cbind

echo "=== 2/3 build the Linux libp2p .lgx (~6-15 min) ==="
LOGOS_ROOT="$SIBLINGS" bash "$REPO_ROOT/docker/build_lgx_linux.sh"

echo "=== 3/3 build the base image lp2p-mix-e2e (~30 min first time) ==="
docker build -f "$REPO_ROOT/docker/Dockerfile.testnet-e2e" -t lp2p-mix-e2e "$REPO_ROOT"

cat <<EOF

DONE. Run the sim:
  cd $REPO_ROOT/docker/testnet/mix_e2e
  PHASE=1 bash orchestrate.sh          # mix routing (RLN off)
  PHASE=2 bash orchestrate.sh          # full 3-hop RLN-over-mix delivery
  PHASE=2 NEG=1 bash orchestrate.sh    # negative: unregistered sender rejected
  docker compose down                  # tear down
EOF
