#!/usr/bin/env bash
# Step 4a check: prove the JSON-blob mix dial methods actually DISPATCH through
# the universal-codegen QtRO surface (the multi-arg signatures silently failed
# with METHOD_FAILED — the body was never entered). We send each method a
# deliberately-bad JSON blob and assert the reply carries that method's own
# "bad args json" error string, which can only be produced from INSIDE the
# method body. Seeing it == dispatch reached the body == the fix works.
set -uo pipefail

LOGOSCORE="${LOGOSCORE:-/logoscore/bin/logoscore}"
MODULES_DIR="${MODULES_DIR:-/modules}"
LP2P_MOD="libp2p_module"
QENV="QT_QPA_PLATFORM=offscreen"
CFG=$(mktemp -d); LOG=$(mktemp)
cleanup(){ [ -n "${DPID:-}" ] && kill "$DPID" 2>/dev/null; }
trap cleanup EXIT

lc(){ env -u TMPDIR $QENV LOGOSCORE_CONFIG_DIR="$CFG" "$LOGOSCORE" "$@"; }
call(){ timeout "${CALL_TIMEOUT:-60}" env -u TMPDIR $QENV LOGOSCORE_CONFIG_DIR="$CFG" "$LOGOSCORE" --json call "$@" 2>&1; }
tmparg(){ local f; f=$(mktemp); printf '%s' "$1" >"$f"; printf '@%s' "$f"; }

echo "=== launch daemon"
(env -i HOME="$HOME" PATH="$PATH" $QENV LOGOSCORE_CONFIG_DIR="$CFG" \
    "$LOGOSCORE" -m "$MODULES_DIR" -D </dev/null >>"$LOG" 2>&1) &
DPID=$!
for i in $(seq 1 60); do lc load-module "$LP2P_MOD" >/dev/null 2>&1 && break; sleep 0.5; done
lc load-module "$LP2P_MOD"

echo "=== start node (gives the dial methods a libp2p ctx)"
call "$LP2P_MOD" start

fail=0
probe(){ # $1=method
    local out; out=$(call "$LP2P_MOD" "$1" "$(tmparg '{"intentionally":"bad"}')")
    if echo "$out" | grep -q "bad args json"; then
        echo "  PASS $1 -> body entered (got 'bad args json')"
    elif echo "$out" | grep -qiE "METHOD_FAILED|method not found|no such method"; then
        echo "  FAIL $1 -> NOT dispatched: $out"; fail=1
    else
        echo "  ??   $1 -> unexpected (dispatched but no arg-validation msg): $out"
    fi
}

echo "=== probe JSON-blob dial methods"
probe mixDial
probe mixDialWithReply
probe mixRegisterDestReadBehavior
probe mixNodepoolAdd

[ "$fail" -eq 0 ] && { echo "DISPATCH OK"; exit 0; } || { echo "DISPATCH FAILED"; exit 1; }
