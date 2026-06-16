#!/usr/bin/env bash
# Phase 5 (path C) daemon-load smoke: prove the RLN-enabled logos-libp2p-module
# loads in a logoscore daemon and starts a mix node. Isolated config/modules
# dir + ephemeral listen addr so it does not disturb a running sim.
#
# Usage: daemon_smoke.sh <libp2p_module.lgx>
set -uo pipefail

LGX="${1:?usage: daemon_smoke.sh <libp2p_module.lgx>}"
LOGOSCORE="${LOGOSCORE:-/logoscore/bin/logoscore}"
PLATFORM="${PLATFORM:-linux-arm64-dev}"

WORK=$(mktemp -d); MDIR="$WORK/modules"; CFG="$WORK/cfg"; mkdir -p "$MDIR" "$CFG"
LOG="$WORK/daemon.log"
cleanup() { [ -n "${DPID:-}" ] && kill "$DPID" 2>/dev/null; }
trap cleanup EXIT

install_lgx() {
    local lgx="$1" name tmp
    name=$(tar xzOf "$lgx" manifest.json | python3 -c 'import json,sys;print(json.load(sys.stdin)["name"])')
    tmp=$(mktemp -d); tar xzf "$lgx" -C "$tmp"
    mkdir -p "$MDIR/$name"
    cp "$tmp/manifest.json" "$MDIR/$name/manifest.json"
    cp -L "$tmp"/variants/"$PLATFORM"/* "$MDIR/$name/"
    printf '%s' "$PLATFORM" > "$MDIR/$name/variant"
    rm -rf "$tmp"
    echo "$name"
}

call() { env -u TMPDIR QT_QPA_PLATFORM=offscreen LOGOSCORE_CONFIG_DIR="$CFG" "$LOGOSCORE" --json call "$@" 2>&1; }

NAME=$(install_lgx "$LGX")
echo "installed module: $NAME"

(cd "$WORK" && env -i HOME="$HOME" PATH="$PATH" QT_QPA_PLATFORM=offscreen LOGOSCORE_CONFIG_DIR="$CFG" \
    "$LOGOSCORE" -m "$MDIR" -D </dev/null >>"$LOG" 2>&1) &
DPID=$!
echo "daemon pid $DPID"

# Wait for daemon readiness via load-module.
deadline=$((SECONDS + 40)); loaded=0
while (( SECONDS < deadline )); do
    if timeout 10 env -u TMPDIR QT_QPA_PLATFORM=offscreen LOGOSCORE_CONFIG_DIR="$CFG" "$LOGOSCORE" load-module "$NAME" >/dev/null 2>&1; then
        loaded=1; break
    fi
    sleep 0.5
done
[ "$loaded" = 1 ] || { echo "FAIL: load-module timed out"; tail -20 "$LOG"; exit 1; }
echo "loaded $NAME"

echo "--- call start ---"; call "$NAME" start
echo "--- call peerInfo ---"; call "$NAME" peerInfo
echo "--- call stop ---"; call "$NAME" stop
echo "--- daemon log tail ---"; tail -15 "$LOG"
