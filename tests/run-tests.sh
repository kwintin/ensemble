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

echo "== signal classifier =="
source "$ROOT/scripts/lib/signal.sh"
ef="$(mktemp)"; se="$(mktemp)"; echo "Error: quota exceeded for model" >"$ef"
code="$(ens_classify 1 "$ef" codex 2>"$se")"; sig="$(cat "$se")"
check "quota -> exit 10" 10 "$code"
check "quota -> ENS_SIGNAL" 0 0 'ENS_SIGNAL {"status":"QUOTA_EXHAUSTED"' "$sig"
echo "please sign in" >"$ef"; code="$(ens_classify 1 "$ef" codex 2>/dev/null)"
check "auth -> exit 11" 11 "$code"
rm -f "$ef" "$se"

echo "== roster =="
source "$ROOT/scripts/lib/roster.sh"
R="$ROOT/roster.json"
check "codex adapter" 0 0 "codex" "$(ens_endpoint_field "$R" gpt-5.5@codex adapter)"
check "codex model"   0 0 "gpt-5.5" "$(ens_endpoint_field "$R" gpt-5.5@codex model)"
check "codex family"  0 0 "openai"  "$(ens_family_of "$R" gpt-5.5@codex)"
check "enabled lists codex" 0 0 "gpt-5.5@codex" "$(ens_endpoints_enabled "$R")"

echo "== verdict normalizer =="
source "$ROOT/scripts/lib/verdict.sh"
rf="$(mktemp)"
cat >"$rf" <<'J'
{"verdict":"CHANGES","findings":[{"file":"a.py","line":4,"severity":"high","issue":"off-by-one"}]}
J
out="$(ens_normalize_verdict gpt-5.5@codex json "$rf")"
check "json verdict parsed" 0 0 '"verdict": "CHANGES"' "$out"
check "json endpoint stamped" 0 0 'gpt-5.5@codex' "$out"
printf '===VERDICT=== APPROVED\nlooks good\n===END===\n' >"$rf"
out="$(ens_normalize_verdict agy@agy sentinel "$rf")"
check "sentinel verdict parsed" 0 0 '"verdict": "APPROVED"' "$out"
printf 'not json at all' >"$rf"
out="$(ens_normalize_verdict ep json "$rf")"
check "malformed json -> ERROR" 0 0 '"verdict": "ERROR"' "$out"
printf 'no sentinel here\n' >"$rf"
out="$(ens_normalize_verdict ep sentinel "$rf")"
check "sentinel no match -> ERROR" 0 0 '"verdict": "ERROR"' "$out"
rm -f "$rf"

echo "== codex adapter =="
source "$ROOT/scripts/lib/timeout.sh"
source "$ROOT/scripts/adapters/codex.sh"
pf="$(mktemp)"; of="$(mktemp)"; echo "review this diff" >"$pf"
STUB_MODE=ok codex_review gpt-5.5@codex gpt-5.5 medium "$pf" "$of"; rc=$?
check "codex_review rc 0" 0 "$rc"
check "codex_review wrote verdict json" 0 0 '"verdict"' "$(cat "$of")"
check "codex_health ok" 0 0 "ok" "$(STUB_MODE=ok codex_health)"
check "codex_health auth" 0 0 "auth" "$(STUB_MODE=auth codex_health)"
check "codex_list_models" 0 0 "gpt-5.5" "$(STUB_MODE=ok codex_list_models)"
rm -f "$pf" "$of"

echo ""; echo "PASS=$PASS FAIL=$FAIL"; [ "$FAIL" -eq 0 ]
