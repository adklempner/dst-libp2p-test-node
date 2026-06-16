#!/usr/bin/env bash
# Orchestrate the 5-node RLN-over-mix E2E on the new universal logos-libp2p-module
# stack, via docker-compose (one daemon per container, all on a shared network).
#
#   PHASE=1 : bring up 5 nodes, mesh the mix pool, sender one-way mixDial -> dest
#             (RLN OFF) -> proves Sphinx routing through OUR module end to end.
#   PHASE=2 : every node registers a DISTINCT RLN identity on testnet (per-hop
#             mix RLN: each hop verifies the incoming proof AND regenerates one
#             for the next hop, so every mix node must be a member). The sender
#             dials; the proof is verified + regenerated at each of the 3 hops
#             and delivered to the dest.
#
# Multi-identity registration: generate_identity is a pure function of a 32-byte
# seed and register_member uses the holding account only as funder/signer, so ONE
# funded payment account registers all 5 distinct identities (distinct seeds ->
# distinct leaves). rlnRegister takes an optional "seed" to decouple the two.
# Registrations run sequentially (each node re-syncs first) to avoid nonce races
# on the shared payment account.
#
# Roles: sender + relay1/relay2/relay3 + dest. In PHASE 2 ALL are RLN members.
# Setup order: rlnEnable MUST precede mixSetNodeInfo (factory read at mix mount).
# Mesh keys host-derived (keys.py). Node addr = /ip4/<container-ip>/tcp/9000.
# bash 3.2 (macOS): no associative arrays; per-node values via sv/gv.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DC="docker compose -f $HERE/docker-compose.yml"
KEYS="python3 $HERE/keys.py"
LOGOSCORE=/logoscore/bin/logoscore
PHASE="${PHASE:-1}"
# NEG=1 (with PHASE=2): negative test — register relays+dest but leave the SENDER
# UNREGISTERED (RLN enabled, mix mounted, no membership/proof). Its mixDial must
# be rejected (no valid proof) and the message must NOT reach the dest, proving
# RLN enforcement (vs the happy path where a registered sender's message lands).
NEG="${NEG:-0}"
PROTO="${MSG_PROTO:-/ipfs/ping/1.0.0}"
# Message exchange: src and dest do request/reply round-trips over the mix
# (mixDialWithReply + SURB return path). /ipfs/ping echoes the request, so each
# round-trip = one request (initiator->peer) + one reply (peer->initiator), both
# RLN-enforced in PHASE=2. MSG_COUNT round-trips per initiator; BIDIR=1 means both
# src and dest initiate (they message each other); READ_SIZE matches the echo
# (32 for ping). N round-trips = N dials (the reply future is one-shot).
MSG_COUNT="${MSG_COUNT:-3}"
READ_SIZE="${READ_SIZE:-32}"
BIDIR="${BIDIR:-1}"
MSG_INTERVAL="${MSG_INTERVAL:-0}"
RELAYS="relay1 relay2 relay3"
ALL="relay1 relay2 relay3 dest sender"
RPC_URL="${RPC_URL:-https://testnet.lez.logos.co/}"
RATE="${RATE:-100}"
SYNC_STEP="${SYNC_STEP:-3000}"
WALLET_MOD="liblogos_execution_zone_wallet_module"
RLN_MOD="liblogos_rln_module"

sv(){ eval "_${1}_${2}=\"\$3\""; }
gv(){ eval "printf '%s' \"\${_${1}_${2}:-}\""; }
dexec(){ local svc="$1"; shift; $DC exec -T "$svc" "$@" 2>&1; }
jcall(){ local svc="$1" mod="$2" meth="$3" json="$4"
  printf '%s' "$json" | $DC exec -T "$svc" sh -c 'cat > /tmp/arg.json'
  dexec "$svc" "$LOGOSCORE" --json call "$mod" "$meth" @/tmp/arg.json
}
call(){ local svc="$1" mod="$2" meth="$3"; shift 3; dexec "$svc" "$LOGOSCORE" --json call "$mod" "$meth" "$@"; }
lc(){ local svc="$1"; shift; dexec "$svc" "$LOGOSCORE" "$@"; }
jval(){ python3 -c 'import json,sys
try:
  d=json.load(sys.stdin); r=d.get("result"); print(r.get("value") if isinstance(r,dict) else r)
except Exception: print("ERR")'; }
svc_ip(){ docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$($DC ps -q "$1")"; }
chain_head(){ curl -s -m 15 -X POST "$RPC_URL" -H 'content-type: application/json' --data '{"jsonrpc":"2.0","method":"getLastBlockId","params":[],"id":1}' | python3 -c 'import json,sys;print(json.load(sys.stdin)["result"])'; }
sync_wallet(){ local svc="$1" head cur n
  head=$(chain_head); cur=$(call "$svc" "$WALLET_MOD" get_last_synced_block | jval)
  while [ "$cur" != "$head" ] 2>/dev/null; do
    local tgt=$((cur+SYNC_STEP)); [ $tgt -gt $head ] && tgt=$head
    call "$svc" "$WALLET_MOD" sync_to_block $tgt >/dev/null 2>&1
    n=$(call "$svc" "$WALLET_MOD" get_last_synced_block | jval); [ "$n" = "$cur" ] && break; cur=$n
  done
  echo "$cur"
}

# Diagnose a failed/again-unconfirmed registration by scanning the node's logs
# for the rln program's assert strings, then print the exact remediation.
LEZ_RLN_DIR="${LEZ_RLN_DIR:-<your logos-lez-rln clone>}"
diagnose_reg(){ local svc="$1"; local logs
  logs=$($DC logs --since 900s "$svc" 2>&1)
  echo "  !! RLN registration for '$svc' did not confirm on-chain." >&2
  if echo "$logs" | grep -qiE "Insufficient balance|may be out of funds|range end index 49"; then
    cat >&2 <<EOF
  CAUSE: the shared payment account is OUT OF RLNTOK (each register costs
         price_per_unit*rate; the funded account holds a finite amount).
  FIX: mint a fresh funded payment account by re-running setup, then re-run with
       HOLDING_ACCT pointed at it (no image rebuild needed):
    cd "$LEZ_RLN_DIR/lez-rln" && source ../testnet/env.sh && cargo run --bin run_setup
    HOLDING_ACCT=\$(cat ~/.logos-lez-rln/payment_account_*.txt) PHASE=2 bash orchestrate.sh
  If you instead saw "supply holding may be out of funds", the master supply is
  exhausted -> do the full tree re-deploy (see "tree full" below / REPRODUCE.md).
EOF
  elif echo "$logs" | grep -qiE "Would exceed max total rate limit|max_total_rate_limit"; then
    cat >&2 <<EOF
  CAUSE: the RLN rate-limit pool is exhausted (the tree is effectively full).
  FIX: bump the tree and re-deploy (TREE_ID is a compiled-in constant, not env):
    1. edit TREE_ID in $LEZ_RLN_DIR/lez-rln/src/rln/client.rs (new 32 bytes)
    2. cd "$LEZ_RLN_DIR/lez-rln" && cargo build --bin run_setup --bin register_member
    3. rm -f ../testnet/storage.json ../testnet/supply_holding.txt \\
            ~/.logos-lez-rln/supply_holding_*.txt ~/.logos-lez-rln/payment_account_*.txt
    4. source ../testnet/env.sh && cargo run --bin run_setup
    5. refresh testnet/{config_account,payment_account,supply_holding}.txt + storage.json.seed
    6. rebuild the image: docker build -f docker/Dockerfile.testnet-e2e -t lp2p-mix-e2e .
  See REPRODUCE.md "Troubleshooting" for the full procedure.
EOF
  else
    cat >&2 <<EOF
  CAUSE: unknown. Inspect the node log:
    docker compose -f docker-compose.yml logs $svc | grep -iE 'register|balance|rate limit|payment|tree'
  Most common is out-of-funds -> re-run run_setup (see REPRODUCE.md Troubleshooting).
EOF
  fi
}

# Account overrides (default to the baked testnet fixtures). Set HOLDING_ACCT to a
# freshly-funded payment account (from run_setup) to recover from out-of-funds
# without rebuilding the image; CONFIG_ACCT to target a different tree.
CONFIG_ACCT="${CONFIG_ACCT:-}"; HOLDING_ACCT="${HOLDING_ACCT:-}"

echo "=== up: 5 daemons ==="
$DC up -d
for s in $ALL; do
  for i in $(seq 1 90); do lc "$s" load-module libp2p_module >/dev/null 2>&1 && break; sleep 1; done
done

if [ "$PHASE" = "2" ]; then
  [ -n "$CONFIG_ACCT" ]  || CONFIG_ACCT=$(dexec sender sh -c 'tr -d "\n\r" < /testnet/config_account.txt')
  [ -n "$HOLDING_ACCT" ] || HOLDING_ACCT=$(dexec sender sh -c 'tr -d "\n\r" < /testnet/payment_account.txt')
  echo "  config=$CONFIG_ACCT holding(funder)=$HOLDING_ACCT"
fi

echo "=== per-node setup (load chain -> [wallet+rln] -> start -> mixSetNodeInfo -> peerInfo -> [register]) ==="
for s in $ALL; do
  lc "$s" load-module "$WALLET_MOD" >/dev/null 2>&1
  lc "$s" load-module "$RLN_MOD" >/dev/null 2>&1
  lc "$s" load-module libp2p_module >/dev/null 2>&1
  priv=$(python3 -c 'import os;print(os.urandom(32).hex())'); sv MIXPRIV "$s" "$priv"
  sv MIXPUB "$s" "$($KEYS mixpub "$priv")"
  ip=$(svc_ip "$s"); sv MADDR "$s" "/ip4/$ip/tcp/9000"

  if [ "$PHASE" = "2" ]; then
    dexec "$s" sh -c '[ -f /testnet/storage.json ] || cp /testnet/storage.json.seed /testnet/storage.json'
    call "$s" "$WALLET_MOD" open /testnet/wallet_config.json /testnet/storage.json >/dev/null 2>&1
    synced=$(sync_wallet "$s"); echo "  $s wallet synced to $synced"
    jcall "$s" libp2p_module rlnEnable "{\"useOnchainLEZ\":true,\"configAccount\":\"$CONFIG_ACCT\",\"userMessageLimit\":$RATE,\"epochDurationSeconds\":10.0}" >/dev/null 2>&1
  fi

  call "$s" libp2p_module start >/dev/null 2>&1
  jcall "$s" libp2p_module mixSetNodeInfo "{\"multiaddr\":\"$(gv MADDR "$s")\",\"mixPrivKeyHex\":\"$priv\"}" >/dev/null 2>&1
  pid=$(call "$s" libp2p_module peerInfo | python3 -c 'import json,sys
try: print(json.load(sys.stdin)["result"]["value"]["peerId"])
except Exception: print("")')
  sv PEERID "$s" "$pid"
  sv LPPUB "$s" "$($KEYS peerpub "$pid" 2>/dev/null || echo DECODE_FAIL)"

  if [ "$PHASE" = "2" ] && [ "$NEG" = "1" ] && [ "$s" = "sender" ]; then
    # Negative test: leave the sender UNREGISTERED (no membership, no cached
    # proof). rlnEnable + mix are already set up above; we just skip rlnRegister.
    echo "  $s peerId=${pid:-EMPTY} UNREGISTERED (negative) rlnIsReady=$(call "$s" libp2p_module rlnIsReady | jval)"
  elif [ "$PHASE" = "2" ]; then
    # Distinct identity seed per node; ONE funded account (HOLDING_ACCT) signs.
    # Retry transient failures (METHOD_FAILED / sequencer hiccup on a shared
    # testnet); rlnRegister is idempotent on the same seed (a confirmed
    # commitment returns its existing leaf), so retrying is safe. A persistent
    # failure (out of funds / tree full) is then diagnosed.
    seed=$(python3 -c 'import os;print(os.urandom(32).hex())')
    idc=""; lopt=""; reg=""
    for attempt in 1 2 3 4; do
      reg=$(jcall "$s" libp2p_module rlnRegister "{\"config\":\"$CONFIG_ACCT\",\"wallet\":\"$HOLDING_ACCT\",\"seed\":\"$seed\",\"rate\":$RATE}")
      eval "$(echo "$reg" | python3 -c 'import json,sys
try:
  v=json.load(sys.stdin)["result"]["value"]; print("lopt=%s; idc=%s"%(v["leaf_index"],v["id_commitment"]))
except Exception: print("lopt=ERR; idc=")')"
      [ -n "$idc" ] && break
      echo "  $s rlnRegister attempt $attempt failed ($reg) — re-sync + retry in ${REG_RETRY_SLEEP:-15}s" >&2
      sync_wallet "$s" >/dev/null 2>&1; sleep "${REG_RETRY_SLEEP:-15}"
    done
    # Still no idCommitment after retries -> diagnose (funds/tree/etc.) and stop.
    if [ -z "$idc" ]; then echo "  rlnRegister response: $reg" >&2; diagnose_reg "$s"; exit 1; fi
    # BARRIER: wait until THIS registration is CONFIRMED on-chain (the rln module
    # reports registered:true for our idCommitment) BEFORE the next node
    # registers. is_member_registered reads the canonical tree, so once true the
    # tree has truly grown -> the next node gets a DISTINCT leaf (the rlnIsReady
    # barrier was unreliable: get_merkle_proofs returns a proof for the optimistic
    # leaf before the tree advances, so leaves collided). We also read the ACTUAL
    # leaf and flag any mismatch with the optimistic one.
    lact=""; conf=false
    for w in $(seq 1 80); do
      res=$(call "$s" "$RLN_MOD" is_member_registered "$CONFIG_ACCT" "$idc")
      eval "$(echo "$res" | python3 -c 'import json,sys
try:
  r=json.loads(json.load(sys.stdin)["result"]); print("conf=%s; lact=%s"%(str(r.get("registered",False)).lower(), r.get("leaf_index","")))
except Exception: print("conf=false; lact=")')"
      [ "$conf" = "true" ] && break
      sleep 10
    done
    # Not confirmed within the window -> the Register tx never landed (out of
    # funds, tree full, or sequencer issue). Diagnose and stop.
    if [ "$conf" != "true" ]; then diagnose_reg "$s"; exit 1; fi
    rdy=False; for w in $(seq 1 40); do rdy=$(call "$s" libp2p_module rlnIsReady | jval); [ "$rdy" = "True" ] && break; sleep 10; sync_wallet "$s" >/dev/null 2>&1; done
    flag=""; [ "$lopt" != "$lact" ] && flag=" !! LEAF MISMATCH (proof for $lopt, actual $lact)"
    echo "  $s peerId=${pid:-EMPTY} leaf_opt=$lopt leaf_actual=$lact confirmed=$conf rlnIsReady=$rdy$flag"
  else
    echo "  $s peerId=${pid:-EMPTY} mixpub=$(gv MIXPUB "$s" | cut -c1-12).. lppub=$(gv LPPUB "$s" | cut -c1-12).."
  fi
done

echo "=== mesh: every node adds the other 4 ==="
for a in $ALL; do for b in $ALL; do [ "$a" = "$b" ] && continue
  jcall "$a" libp2p_module mixNodepoolAdd \
    "{\"peerId\":\"$(gv PEERID "$b")\",\"multiaddr\":\"$(gv MADDR "$b")\",\"mixPubKey\":\"$(gv MIXPUB "$b")\",\"libp2pPubKey\":\"$(gv LPPUB "$b")\"}" >/dev/null 2>&1
done; done
echo "  meshed."

if [ "$PHASE" = "2" ]; then
  echo "=== rlnIsReady status (each node was confirmed ready before the next registered) ==="
  line="  "; for s in $ALL; do line="$line $s=$(call "$s" libp2p_module rlnIsReady | jval)"; done; echo "$line"
fi

echo "=== register dest-read-behavior on all nodes (the SURB exit is random) ==="
for s in $ALL; do
  jcall "$s" libp2p_module mixRegisterDestReadBehavior "{\"proto\":\"$PROTO\",\"behavior\":0,\"sizeParam\":$READ_SIZE}" >/dev/null 2>&1
done
echo "  registered ($PROTO, READ_EXACTLY, $READ_SIZE bytes)"

# One request/reply round-trip: dial-with-reply -> write request -> read the SURB
# reply -> close+release. Returns 0 iff a reply came back (read succeeded). N
# round-trips = N dials (the reply future is one-shot).
roundtrip(){ local from="$1" to="$2" idx="$3" dial sid payload rd
  dial=$(jcall "$from" libp2p_module mixDialWithReply \
    "{\"peerId\":\"$(gv PEERID "$to")\",\"multiaddr\":\"$(gv MADDR "$to")\",\"proto\":\"$PROTO\",\"expectReply\":1,\"numSurbs\":1}")
  sid=$(echo "$dial" | jval)
  case "$sid" in ""|ERR|None) return 1;; esac
  # ASCII payload exactly READ_SIZE bytes (ping echoes it back).
  payload=$(python3 -c "print(('m%d-%s'%(${idx},'$from'))[:${READ_SIZE}].ljust(${READ_SIZE},'.'))")
  call "$from" libp2p_module streamWrite "$sid" "$payload" >/dev/null 2>&1
  rd=$(call "$from" libp2p_module streamReadExactly "$sid" "$READ_SIZE")
  call "$from" libp2p_module streamClose "$sid" >/dev/null 2>&1
  call "$from" libp2p_module streamRelease "$sid" >/dev/null 2>&1
  echo "$rd" | grep -q '"success":true'
}

run_dir(){ local from="$1" to="$2" ok=0 i
  for i in $(seq 1 "$MSG_COUNT"); do
    roundtrip "$from" "$to" "$i" && ok=$((ok+1))
    [ "$MSG_INTERVAL" -gt 0 ] && sleep "$MSG_INTERVAL"
  done
  echo "  $from->$to: $ok/$MSG_COUNT replies received"
  LAST_OK=$ok
}

echo "=== exchange: $MSG_COUNT request/reply round-trip(s) per initiator (BIDIR=$BIDIR) ==="
run_dir sender dest; SD=$LAST_OK; DS=0
# In NEG mode only the (unregistered) sender->dest direction is the test.
if [ "$BIDIR" = "1" ] && [ "$NEG" != "1" ]; then run_dir dest sender; DS=$LAST_OK; fi
sleep 4

echo "=== observe: RLN proofs (forward request + SURB reply legs) ==="
vtot=0
for n in $ALL; do
  g=$($DC logs --since 240s "$n" 2>&1 | grep -c 'Generated RLN proof successfully')
  v=$($DC logs --since 240s "$n" 2>&1 | grep -c 'Proof verified successfully')
  echo "  $n: generated=$g verified=$v"; vtot=$((vtot+v))
done
sgen=$($DC logs --since 240s sender 2>&1 | grep -c 'Generated RLN proof successfully')
echo "  replies: sender->dest=$SD dest->sender=$DS ; total verifications=$vtot ; sender proofs=$sgen"

echo "=== VERDICT ==="
if [ "$PHASE" = "2" ] && [ "$NEG" = "1" ]; then
  if [ "$SD" = "0" ] && [ "$sgen" = "0" ]; then
    echo "  PASS (negative): unregistered sender got 0 replies and generated 0 proofs -> rejected."
  else
    echo "  FAIL (negative): expected 0 replies / 0 sender proofs, got replies=$SD sgen=$sgen"
  fi
else
  exp="sender->dest=$MSG_COUNT"; ok=1
  [ "$SD" = "$MSG_COUNT" ] || ok=0
  if [ "$BIDIR" = "1" ]; then exp="$exp dest->sender=$MSG_COUNT"; [ "$DS" = "$MSG_COUNT" ] || ok=0; fi
  if [ "$ok" = "1" ]; then echo "  PASS: every round-trip got a reply ($exp)."
  else echo "  FAIL: expected $exp, got sender->dest=$SD dest->sender=$DS"; fi
fi
echo "DONE (PHASE=$PHASE NEG=$NEG MSG_COUNT=$MSG_COUNT BIDIR=$BIDIR)"
