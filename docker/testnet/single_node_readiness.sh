#!/usr/bin/env bash
# Phase 5 (path C, testnet) — single-node RLN readiness against the hosted LEZ
# testnet (no local sequencer). Loads wallet + rln + libp2p_module in one
# logoscore daemon and drives the new module's RLN flow until rlnIsReady==true.
# This is the plan's Phase-4 live acceptance ("single node reaches
# rlnIsReady()==true after registration"), via testnet RPC.
#
# Accounts/keystores come from the baked testnet fixtures (logos-lez-rln/testnet):
#   config_account.txt   the LEZ RLN config account (rlnEnable + register config)
#   payment_account.txt  the holding/payment account that funds Register txs
#   storage.json.seed    pre-signed wallet storage (seeded -> storage.json)
#   wallet_config.json   sequencer RPC config
#
# Notes learned from bring-up:
#   * The wallet sync is synchronous and blocks the Qt thread, so a single
#     sync_to_block over thousands of blocks exceeds the QtRO reply timeout.
#     We CHUNK the sync (progress persists in storage.json) — see sync_wallet().
#   * libp2p_module must declare liblogos_rln_module as a manifest dependency
#     (metadata.json) so the daemon grants it a cross-module token; otherwise
#     rlnRegister's proxy call into the rln module throws (METHOD_FAILED).
#   * The GM fetcher reads the membership PDA from the wallet's synced state, so
#     the readiness loop keeps re-syncing the wallet up to the live head.
set -uo pipefail

LOGOSCORE="${LOGOSCORE:-/logoscore/bin/logoscore}"
MODULES_DIR="${MODULES_DIR:-/modules}"
WALLET_HOME="${WALLET_HOME:-/testnet}"
RPC_URL="${RPC_URL:-https://testnet.lez.logos.co/}"
RATE="${RATE:-100}"
SYNC_STEP="${SYNC_STEP:-3000}"
WALLET_MOD="logos_execution_zone"
RLN_MOD="liblogos_rln_module"
LP2P_MOD="libp2p_module"

CONFIG_ACCT="${CONFIG_ACCT:-$(tr -d '\n\r' < "$WALLET_HOME/config_account.txt")}"
HOLDING_ACCT="${HOLDING_ACCT:-$(tr -d '\n\r' < "$WALLET_HOME/payment_account.txt")}"
WALLET_CONFIG="$WALLET_HOME/wallet_config.json"
WALLET_STORAGE="$WALLET_HOME/storage.json"
[ -f "$WALLET_STORAGE" ] || cp "$WALLET_HOME/storage.json.seed" "$WALLET_STORAGE"

export NSSA_WALLET_HOME_DIR="$WALLET_HOME"
CFG=$(mktemp -d); LOG=$(mktemp)
QENV="QT_QPA_PLATFORM=offscreen"
cleanup(){ [ -n "${DPID:-}" ] && kill "$DPID" 2>/dev/null; }
trap cleanup EXIT

lc(){ env -u TMPDIR $QENV LOGOSCORE_CONFIG_DIR="$CFG" NSSA_WALLET_HOME_DIR="$WALLET_HOME" "$LOGOSCORE" "$@"; }
call(){ timeout "${CALL_TIMEOUT:-280}" env -u TMPDIR $QENV LOGOSCORE_CONFIG_DIR="$CFG" NSSA_WALLET_HOME_DIR="$WALLET_HOME" "$LOGOSCORE" --json call "$@" 2>&1; }
tmparg(){ local f; f=$(mktemp); printf '%s' "$1" >"$f"; printf '@%s' "$f"; }
jval(){ python3 -c 'import json,sys
try:
  d=json.load(sys.stdin); r=d.get("result")
  print(r.get("value") if isinstance(r,dict) else r)
except Exception: print("ERR")'; }

chain_head(){ curl -s -m 15 -X POST "$RPC_URL" -H 'content-type: application/json' \
    --data '{"jsonrpc":"2.0","method":"getLastBlockId","params":[],"id":1}' \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"])' 2>/dev/null; }
lsb(){ call "$WALLET_MOD" get_last_synced_block | jval; }

# Chunked, resilient sync up to $1 (default: live head). Progress persists in
# storage.json, so a chunk that overruns the QtRO window is retried from the
# last persisted block on the next iteration.
sync_wallet(){
    local head="${1:-$(chain_head)}" cur n tries=0
    cur=$(lsb)
    while [ "$cur" != "$head" ]; do
        [ "$cur" = "ERR" ] || [ "$cur" = "None" ] && { sleep 3; cur=$(lsb); tries=$((tries+1)); [ $tries -gt 60 ] && { echo "  sync stuck"; return 1; }; continue; }
        local step=$SYNC_STEP; [ $((head-cur)) -lt 8000 ] && step=1500
        local tgt=$((cur+step)); [ $tgt -gt $head ] && tgt=$head
        call "$WALLET_MOD" sync_to_block $tgt >/dev/null 2>&1
        n=$(lsb); [ "$n" = "$cur" ] && tries=$((tries+1)) || tries=0
        cur=$n; [ $tries -gt 60 ] && { echo "  no sync progress"; return 1; }
    done
    echo "  synced to $cur"
}

echo "=== config: config_acct=$CONFIG_ACCT holding_acct=$HOLDING_ACCT rate=$RATE"
echo "=== launch daemon"
(env -i HOME="$HOME" PATH="$PATH" $QENV LOGOSCORE_CONFIG_DIR="$CFG" \
    NSSA_WALLET_HOME_DIR="$WALLET_HOME" \
    "$LOGOSCORE" -m "$MODULES_DIR" -D </dev/null >>"$LOG" 2>&1) &
DPID=$!
for i in $(seq 1 60); do lc load-module "$LP2P_MOD" >/dev/null 2>&1 && break; sleep 0.5; done

echo "=== load modules (order: wallet -> rln -> libp2p)"
lc load-module "$WALLET_MOD" && lc load-module "$RLN_MOD" && lc load-module "$LP2P_MOD"

echo "=== open + sync wallet to head"
call "$WALLET_MOD" open "$WALLET_CONFIG" "$WALLET_STORAGE"
sync_wallet

echo "=== enable RLN (onchain LEZ via testnet) BEFORE mix mount"
RLN_CFG="{\"useOnchainLEZ\":true,\"configAccount\":\"$CONFIG_ACCT\",\"userMessageLimit\":$RATE,\"epochDurationSeconds\":10.0}"
call "$LP2P_MOD" rlnEnable "$(tmparg "$RLN_CFG")"

echo "=== start node + mount mix (mixSetNodeInfo mounts mix -> creates RLN GM)"
call "$LP2P_MOD" start
# mixSetNodeInfo mounts the mix protocol, which runs the RLN SpamProtection
# factory and creates the group manager that rlnRegister's set_identity needs.
# A random 32-byte curve25519 priv key suffices for single-node readiness.
MIXKEYHEX=$(python3 -c 'import os;print(os.urandom(32).hex())')
ADDR=$(call "$LP2P_MOD" peerInfo | python3 -c 'import json,sys
try: print(json.load(sys.stdin)["result"]["value"]["addrs"][0])
except Exception: print("")')
echo "node addr: $ADDR"
call "$LP2P_MOD" mixSetNodeInfo "$(tmparg "{\"multiaddr\":\"$ADDR\",\"mixPrivKeyHex\":\"$MIXKEYHEX\"}")"

echo "=== register membership on testnet (minutes)"
call "$LP2P_MOD" rlnRegister "$(tmparg "{\"config\":\"$CONFIG_ACCT\",\"wallet\":\"$HOLDING_ACCT\",\"rate\":$RATE}")"

echo "=== readiness gate (module self-drives proof refresh via its own timer; host only keeps the wallet synced; up to ~1h)"
DEADLINE=$(( $(date +%s) + ${READY_TIMEOUT:-3600} ))
i=0
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
    i=$((i+1))
    # Keep the wallet synced so the rln module's get_merkle_proofs (driven by the
    # libp2p module's in-module refresh timer) sees the membership PDA. No
    # rlnRefreshProof call here — rlnRegister arms the module's own Qt-thread timer.
    [ $((i % 3)) -eq 1 ] && sync_wallet >/dev/null 2>&1
    R=$(call "$LP2P_MOD" rlnIsReady)
    echo "rlnIsReady -> $(echo "$R" | jval)"
    echo "$R" | grep -q '"value":true' && { echo "READY"; exit 0; }
    sleep 20
done
echo "FAIL: not ready before timeout"; tail -40 "$LOG"; exit 1
