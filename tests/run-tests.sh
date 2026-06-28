#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
source "$HERE/lib.sh"
export PATH="$HERE/stubs:$PATH"   # stubs shadow real CLIs
PASS=0; FAIL=0

echo "== harness =="
out="$(STUB_MODE=ok codex exec --sandbox read-only "hi" 2>/dev/null)"; rc=$?
check "codex stub returns ok" 0 "$rc" "STUB_OK" "$out"

echo "== timeout guard =="
source "$ROOT/scripts/lib/timeout.sh"
ens_run_timeout 2 -- sh -c 'sleep 10'; rc=$?
check "slow command killed -> 124" 124 "$rc"
ens_run_timeout 5 -- sh -c 'echo fast'; rc=$?
check "fast command passes -> 0" 0 "$rc"
ens_run_timeout 1 -- sh -c 'trap "exit 0" TERM; sleep 10'; rc=$?
check "timeout despite TERM-trap -> 124" 124 "$rc"
ens_run_timeout abc -- echo hi >/dev/null 2>&1; rc=$?
check "invalid timeout secs -> 2" 2 "$rc"
crc=0; ens_run_timeout 5 -- sh -c 'kill -SEGV $$' >/dev/null 2>&1 || crc=$?
check "crash signal not mislabeled timeout (>=128, not 124)" 1 "$([ "$crc" -ge 128 ] && [ "$crc" -ne 124 ] && echo 1 || echo 0)"

echo "== signal classifier =="
source "$ROOT/scripts/lib/signal.sh"
ef="$(mktemp)"; se="$(mktemp)"; echo "Error: quota exceeded for model" >"$ef"
code="$(ens_classify 1 "$ef" codex 2>"$se")"; sig="$(cat "$se")"
check "quota -> exit 10" 10 "$code"
check "quota -> ENS_SIGNAL" 0 0 'ENS_SIGNAL {"status":"QUOTA_EXHAUSTED"' "$sig"
echo "please sign in" >"$ef"; code="$(ens_classify 1 "$ef" codex 2>/dev/null)"
check "auth -> exit 11" 11 "$code"
echo "Error: deadline exceeded" >"$ef"; code="$(ens_classify 1 "$ef" codex 2>/dev/null)"
check "timeout -> exit 12" 12 "$code"
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
sandt="$(mktemp)"; STUB_MODE=ok codex exec -o "$sandt" "p" >/dev/null 2>&1; rc=$?
check "stub rejects missing --sandbox read-only -> 90" 90 "$rc"; rm -f "$sandt"

echo "== model-cli review =="
pf="$(mktemp)"; echo "find bugs" > "$pf"
out="$(STUB_MODE=ok bash "$ROOT/scripts/model-cli.sh" review --endpoint gpt-5.5@codex --prompt-file "$pf" 2>/dev/null)"; rc=$?
check "review rc 0" 0 "$rc"
check "review emits normalized verdict" 0 0 '"endpoint": "gpt-5.5@codex"' "$out"
out="$(printf 'find bugs' | STUB_MODE=auth bash "$ROOT/scripts/model-cli.sh" review --endpoint gpt-5.5@codex - 2>/dev/null)"; rc=$?
check "auth failure -> exit 11" 11 "$rc"
out="$(printf 'find bugs' | STUB_MODE=bad bash "$ROOT/scripts/model-cli.sh" review --endpoint gpt-5.5@codex - 2>/dev/null)"; rc=$?
check "ERROR verdict -> exit 3" 3 "$rc"
rm -f "$pf"
out="$(printf x | STUB_MODE=notfound bash "$ROOT/scripts/model-cli.sh" review --endpoint gpt-5.5@codex - 2>/dev/null)"; rc=$?
check "missing codex (127) -> exit 13" 13 "$rc"
badr="$(mktemp)"; printf '%s' '{"endpoints":[{"id":"x@codex","adapter":"codex","model":"gpt-5.5","effort":"bad effort","structured_output":"json","enabled":true}]}' > "$badr"
out="$(printf x | ENSEMBLE_ROSTER="$badr" bash "$ROOT/scripts/model-cli.sh" review --endpoint x@codex - 2>/dev/null)"; rc=$?
check "invalid effort -> exit 1" 1 "$rc"; rm -f "$badr"
out="$(printf x | ENSEMBLE_ROSTER=/no/such/roster.json bash "$ROOT/scripts/model-cli.sh" review --endpoint x@codex - 2>/dev/null)"; rc=$?
check "model-cli missing roster -> clean exit 1" 1 "$rc"

echo "== doctor =="
out="$(STUB_MODE=ok bash "$ROOT/scripts/doctor.sh" 2>&1)"; rc=$?
check "doctor reports codex ok" 0 "$rc" "gpt-5.5@codex: ok" "$out"
out="$(STUB_MODE=auth bash "$ROOT/scripts/doctor.sh" 2>&1)"; rc=$?
check "doctor flags auth -> exit 1" 1 "$rc" "auth" "$out"
out="$(ENSEMBLE_ROSTER=/no/such/roster.json bash "$ROOT/scripts/doctor.sh" 2>/dev/null)"; rc=$?
check "doctor missing roster -> exit 1" 1 "$rc"
badj="$(mktemp)"; printf 'not json' > "$badj"
out="$(ENSEMBLE_ROSTER="$badj" bash "$ROOT/scripts/doctor.sh" 2>/dev/null)"; rc=$?
check "doctor invalid-json roster -> exit 1" 1 "$rc"; rm -f "$badj"
badr2="$(mktemp)"; printf '%s' '{"endpoints":42}' > "$badr2"
out="$(ENSEMBLE_ROSTER="$badr2" bash "$ROOT/scripts/doctor.sh" 2>/dev/null)"; rc=$?
check "doctor non-list endpoints -> exit 1" 1 "$rc"; rm -f "$badr2"

echo "== plugin contract =="
python3 - "$ROOT" <<'PY'; rc=$?
import json,os,sys,stat
root=sys.argv[1]; errs=[]
pj=json.load(open(os.path.join(root,".claude-plugin","plugin.json")))
if pj.get("name")!="ensemble": errs.append("plugin name != ensemble")
if not pj.get("version"): errs.append("missing version")
for s in ("scripts/model-cli.sh","scripts/doctor.sh","tests/run-tests.sh","tests/stubs/codex"):
    p=os.path.join(root,s)
    if not os.path.isfile(p): errs.append("missing "+s)
    elif not (os.stat(p).st_mode & stat.S_IXUSR): errs.append("not executable: "+s)
if errs:
    [print("  -",e) for e in errs]; sys.exit(1)
PY
check "plugin contract holds" 0 "$rc"

echo ""; echo "PASS=$PASS FAIL=$FAIL"; [ "$FAIL" -eq 0 ]
