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

echo ""; echo "PASS=$PASS FAIL=$FAIL"; [ "$FAIL" -eq 0 ]
