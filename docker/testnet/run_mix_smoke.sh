#!/usr/bin/env bash
# Step 4b: build + run the 5-node in-process mix dial-with-reply smoke test
# (nim-libp2p-mix/cbind/examples/mix.c) to validate multi-node Sphinx routing
# (PathLength=3, exit!=dest) end to end. Success = the SURB reply round-trips
# ("Read 32 bytes", exit 0). See MIX_MULTINODE_VALIDATION.md for why RLN
# gen/verify is validated separately (cbind global-GM limit).
set -euo pipefail

MIX_REPO="${MIX_REPO:-$HOME/Waku/Logos/nim-libp2p-mix}"
CBIND="$MIX_REPO/cbind"
cd "$CBIND"

echo "=== build cbind (nix build .#cbind) ==="
[ -e result ] || nix build .#cbind -L
RES=$(readlink -f result)
echo "cbind result: $RES"

# Locate the static/shared lib + header the example links against.
HDR=$(find -L "$RES" "$CBIND" -name 'libp2p.h' 2>/dev/null | head -1)
LIB=$(find -L "$RES" -name 'libp2p.a' 2>/dev/null | head -1)
[ -n "$LIB" ] || LIB=$(find -L "$RES" -name 'libp2p.so' -o -name 'libp2p.dylib' 2>/dev/null | head -1)
[ -n "$HDR" ] && [ -n "$LIB" ] || { echo "missing header/lib (hdr=$HDR lib=$LIB)"; ls -R "$RES" | head -40; exit 1; }
echo "header: $HDR"; echo "lib: $LIB"

OUT=$(mktemp -d)
echo "=== compile mix.c ==="
# nim's std/sysrand pulls SecRandomCopyBytes on darwin → needs the Security +
# CoreFoundation frameworks at link time.
EXTRA_LDFLAGS="-pthread"
[ "$(uname)" = "Darwin" ] && EXTRA_LDFLAGS="$EXTRA_LDFLAGS -framework Security -framework CoreFoundation"
g++ -I"$(dirname "$HDR")" -I"$CBIND" -o "$OUT/mix" "$CBIND/examples/mix.c" "$LIB" $EXTRA_LDFLAGS

echo "=== run 5-node mix dial-with-reply ==="
LOG="$OUT/mix.log"
if timeout 120 "$OUT/mix" >"$LOG" 2>&1; then RC=0; else RC=$?; fi
tail -30 "$LOG"
echo "----"
if grep -q "Read 32 bytes" "$LOG"; then
    echo "MIX ROUTING OK (5-node dial + SURB reply round-trip)"; exit 0
else
    echo "MIX ROUTING FAILED (rc=$RC, no reply round-trip)"; exit 1
fi
