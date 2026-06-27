#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
source "$HERE/lib.sh"
export PATH="$HERE/stubs:$PATH"   # stubs shadow real CLIs
PASS=0; FAIL=0

echo "== harness =="
out="$(STUB_MODE=ok codex exec "hi" 2>/dev/null)"; rc=$?
check "codex stub returns ok" 0 "$rc" "STUB_OK" "$out"

echo "== timeout guard =="
source "$ROOT/scripts/lib/timeout.sh"
ens_run_timeout 2 -- sh -c 'sleep 10'; rc=$?
check "slow command killed -> 124" 124 "$rc"
ens_run_timeout 5 -- sh -c 'echo fast'; rc=$?
check "fast command passes -> 0" 0 "$rc"

echo ""; echo "PASS=$PASS FAIL=$FAIL"; [ "$FAIL" -eq 0 ]
