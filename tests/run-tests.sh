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
# a model that echoes the instruction (APPROVED) before its real verdict (CHANGES)
# must resolve to the LAST/closed verdict, not the first
printf 'I will print ===VERDICT=== APPROVED or CHANGES at the end.\nFound a bug.\n===VERDICT=== CHANGES\n===END===\n' >"$rf"
out="$(ens_normalize_verdict ep sentinel "$rf")"
check "sentinel takes last verdict (echoed instruction ignored)" 0 0 '"verdict": "CHANGES"' "$out"
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

# --- sentinel adapters (agy/grok/vibe/opencode/kilo): verdict via ===VERDICT=== block ---
VIBECFG="$ROOT/tests/fixtures/vibe-config.toml"
adapter_case() { # CLI ENDPOINT MODEL OK_VERDICT MODELS_SUBSTR  [extra env for health/list]
  local cli="$1" ep="$2" model="$3" okv="$4" msub="$5"
  echo "== $cli adapter =="
  source "$ROOT/scripts/adapters/$cli.sh"
  local pf of; pf="$(mktemp)"; of="$(mktemp)"; echo "review this diff" >"$pf"
  STUB_MODE=ok "${cli}_review" "$ep" "$model" medium "$pf" "$of"; rc=$?
  check "${cli}_review rc 0" 0 "$rc"
  check "${cli}_review emitted sentinel" 0 0 '===VERDICT===' "$(cat "$of")"
  check "${cli}_review verdict=$okv" 0 0 "\"verdict\": \"$okv\"" "$(ens_normalize_verdict "$ep" sentinel "$of")"
  STUB_MODE=bad "${cli}_review" "$ep" "$model" medium "$pf" "$of" 2>/dev/null
  check "${cli}_review bad -> ERROR" 0 0 '"verdict": "ERROR"' "$(ens_normalize_verdict "$ep" sentinel "$of")"
  STUB_MODE=auth "${cli}_review" "$ep" "$model" medium "$pf" "$of" 2>/dev/null; rc=$?
  check "${cli}_review auth -> non-zero rc" 0 "$([ "$rc" -ne 0 ] && echo 0 || echo 1)"
  check "${cli}_list_models lists models" 0 0 "$msub" "$(ENS_VIBE_CONFIG="$VIBECFG" STUB_MODE=ok "${cli}_list_models")"
  rm -f "$pf" "$of"
}
adapter_case agy  gemini-3.5-flash@agy     "Gemini 3.5 Flash (Medium)"  CHANGES  "Gemini"
adapter_case grok grok-build@grok          grok-build                   CHANGES  "grok-build"
adapter_case vibe mistral-medium-3.5@vibe  mistral-medium-3.5           CHANGES  "mistral-medium-3.5"
adapter_case opencode deepseek-v4-pro@opencode opencode-go/deepseek-v4-pro APPROVED "deepseek-v4-pro"
adapter_case kilo glm-5.2@kilo             kilo/z-ai/glm-5.2            CHANGES  "glm-5.2"
# health: stub-driven for agy/grok/opencode/kilo; config-driven for vibe (ENS_VIBE_CONFIG)
check "agy_health ok"  0 0 "ok"   "$(STUB_MODE=ok agy_health)"
check "agy_health auth" 0 0 "auth" "$(STUB_MODE=auth agy_health)"
check "grok_health ok" 0 0 "ok"   "$(STUB_MODE=ok grok_health)"
check "grok_health auth" 0 0 "auth" "$(STUB_MODE=auth grok_health)"
check "opencode_health ok" 0 0 "ok" "$(STUB_MODE=ok opencode_health)"
check "opencode_health auth" 0 0 "auth" "$(STUB_MODE=auth opencode_health)"
check "kilo_health ok" 0 0 "ok"   "$(STUB_MODE=ok kilo_health)"
check "kilo_health auth" 0 0 "auth" "$(STUB_MODE=auth kilo_health)"
check "vibe_health ok (config api_key)" 0 0 "ok" "$(ENS_VIBE_CONFIG="$VIBECFG" vibe_health)"
check "vibe_health auth (no config)" 0 0 "auth" "$(ENS_VIBE_CONFIG=/no/such/vibe.toml vibe_health)"
wscfg="$(mktemp)"; printf '[[providers]]\nname = "mistral"\napi_key = "   "\n' > "$wscfg"
check "vibe_health auth (whitespace-only api_key)" 0 0 "auth" "$(ENS_VIBE_CONFIG="$wscfg" vibe_health)"; rm -f "$wscfg"
envcfg="$(mktemp)"; printf '[[providers]]\nname = "mistral"\napi_key_env_var = "ENS_TEST_VIBE_KEY"\n' > "$envcfg"
check "vibe_health ok (api_key_env_var set)" 0 0 "ok" "$(ENS_TEST_VIBE_KEY=secret ENS_VIBE_CONFIG="$envcfg" vibe_health)"
check "vibe_health auth (api_key_env_var unset)" 0 0 "auth" "$(ENS_TEST_VIBE_KEY= ENS_VIBE_CONFIG="$envcfg" vibe_health)"; rm -f "$envcfg"

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
# end-to-end through the real roster: each sentinel adapter dispatched by model-cli
pf="$(mktemp)"; echo "find bugs" > "$pf"
for ep in grok-build@grok deepseek-v4-pro@opencode glm-5.2@kilo mistral-medium-3.5@vibe gemini-3.5-flash@agy; do
  out="$(STUB_MODE=ok bash "$ROOT/scripts/model-cli.sh" review --endpoint "$ep" --prompt-file "$pf" 2>/dev/null)"; rc=$?
  check "model-cli review $ep -> rc 0" 0 "$rc"
  check "model-cli review $ep stamps endpoint" 0 0 "\"endpoint\": \"$ep\"" "$out"
done
# auth -> exit 11 for EVERY sentinel adapter (each stub's distinct auth string must
# match ens_classify), so a per-adapter misclassification is caught
for ep in grok-build@grok deepseek-v4-pro@opencode glm-5.2@kilo mistral-medium-3.5@vibe gemini-3.5-flash@agy; do
  rc=0; printf x | STUB_MODE=auth bash "$ROOT/scripts/model-cli.sh" review --endpoint "$ep" - >/dev/null 2>&1 || rc=$?
  check "model-cli $ep auth -> exit 11" 11 "$rc"
done
# empty fork output (only non-text events) -> exit 3
rc=0; printf x | STUB_MODE=empty bash "$ROOT/scripts/model-cli.sh" review --endpoint deepseek-v4-pro@opencode - >/dev/null 2>&1 || rc=$?
check "model-cli opencode empty -> exit 3" 3 "$rc"
# widened model regex still rejects shell metacharacters
badm="$(mktemp)"; printf '%s' '{"endpoints":[{"id":"x@codex","adapter":"codex","model":"a;rm -rf b","effort":"medium","structured_output":"json","enabled":true}]}' > "$badm"
rc=0; printf x | ENSEMBLE_ROSTER="$badm" bash "$ROOT/scripts/model-cli.sh" review --endpoint x@codex - >/dev/null 2>&1 || rc=$?
check "model with shell metachars rejected -> exit 1" 1 "$rc"; rm -f "$badm"
# read-only invocation is locked: each stub exits 90 if its guard flag is missing
rc=0; STUB_MODE=ok grok -p hi -m m >/dev/null 2>&1 || rc=$?
check "grok stub rejects missing --permission-mode plan -> 90" 90 "$rc"
rc=0; STUB_MODE=ok opencode run -m m -- hi >/dev/null 2>&1 || rc=$?
check "opencode stub rejects missing --format json -> 90" 90 "$rc"
rm -f "$pf"

echo "== doctor =="
out="$(ENS_VIBE_CONFIG="$ROOT/tests/fixtures/vibe-config.toml" STUB_MODE=ok bash "$ROOT/scripts/doctor.sh" 2>&1)"; rc=$?
check "doctor exit 0 (all healthy)" 0 "$rc"
for ep in gpt-5.5@codex grok-build@grok deepseek-v4-pro@opencode glm-5.2@kilo mistral-medium-3.5@vibe gemini-3.5-flash@agy; do
  check "doctor: $ep ok" 0 0 "$ep: ok" "$out"
done
out="$(ENS_VIBE_CONFIG="$ROOT/tests/fixtures/vibe-config.toml" STUB_MODE=auth bash "$ROOT/scripts/doctor.sh" 2>&1)"; rc=$?
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

echo "== reviewer selection =="
RM="$ROOT/tests/fixtures/roster-multi.json"
sel="$(ens_reviewers "$RM" | tr '\n' ' ')"
check "reviewers include role=reviewer and role=both" 0 0 "a@codex b@codex c@codex " "$sel"
printf '%s' "$sel" | grep -q 'x@codex' && { echo "FAIL: executor-only x@codex selected as reviewer"; FAIL=$((FAIL+1)); } || { echo "ok: executor-only excluded"; PASS=$((PASS+1)); }
printf '%s' "$sel" | grep -q 'off@codex' && { echo "FAIL: disabled off@codex selected"; FAIL=$((FAIL+1)); } || { echo "ok: disabled excluded"; PASS=$((PASS+1)); }

echo "== ens-review dispatch =="
RM="$ROOT/tests/fixtures/roster-multi.json"
pf="$(mktemp)"; echo "review this" > "$pf"
# a@codex ok, b@codex auth-fail, c@codex ok  (set per-endpoint STUB via MODE map below)
out="$(ENSEMBLE_ROSTER="$RM" ENS_TEST_MODES='b@codex=auth' bash "$ROOT/scripts/ens-review.sh" --reviewers a@codex,b@codex,c@codex --prompt-file "$pf" 2>/dev/null)"; rc=$?
check "dispatch returns JSON with all three reviewers" 0 0 '"endpoint": "b@codex"' "$out"
check "a@codex ok rc captured" 0 0 '"endpoint": "a@codex"' "$out"
rm -f "$pf"

echo "== ens-review normalize =="
out="$(printf hi | ENSEMBLE_ROSTER="$RM" ENS_TEST_MODES='b@codex=auth' bash "$ROOT/scripts/ens-review.sh" --reviewers a@codex,b@codex - 2>/dev/null)"
check "ok reviewer has status ok + a verdict" 0 0 '"status": "ok"' "$out"
check "ok reviewer verdict extracted" 0 0 '"verdict": "CHANGES"' "$out"
check "auth reviewer degraded with reason auth" 0 0 '"reason": "auth"' "$out"
check "family stamped from roster" 0 0 '"family": "openai"' "$out"
check "reviewer record carries review prose field" 0 0 '"review":' "$out"

echo "== ens-review quorum =="
# 3 reviewers, families openai/xai/openai, all ok -> distinct ok families {openai,xai}=2 >= min_quorum 2 -> met
out="$(printf hi | ENSEMBLE_ROSTER="$RM" bash "$ROOT/scripts/ens-review.sh" --reviewers a@codex,b@codex,c@codex - 2>/dev/null)"; rc=$?
check "quorum met -> exit 0" 0 "$rc"
check "quorum_met true" 0 0 '"quorum_met": true' "$out"
check "family collision record present" 0 0 '"endpoints"' "$out"
# only a@codex ok (1 family) with min_quorum 2 -> below quorum
out2="$(printf hi | ENSEMBLE_ROSTER="$RM" ENS_TEST_MODES='b@codex=auth,c@codex=auth' bash "$ROOT/scripts/ens-review.sh" --reviewers a@codex,b@codex,c@codex - 2>/dev/null)"; rc2=$?
check "below quorum -> exit 4" 4 "$rc2"
# min_quorum typo (999) must be capped at the reviewer count, not render quorum unreachable
capr="$(mktemp)"; printf '%s' '{"min_quorum":999,"endpoints":[{"id":"a@codex","adapter":"codex","model":"gpt-5.5","effort":"medium","structured_output":"json","family":"openai","role":"reviewer","enabled":true},{"id":"b@codex","adapter":"codex","model":"gpt-5.5","effort":"medium","structured_output":"json","family":"xai","role":"reviewer","enabled":true}]}' > "$capr"
out3="$(printf hi | ENSEMBLE_ROSTER="$capr" bash "$ROOT/scripts/ens-review.sh" --reviewers a@codex,b@codex - 2>/dev/null)"; rc3=$?
check "min_quorum 999 capped -> quorum reachable, exit 0" 0 "$rc3"
check "quorum_required capped to reviewer count (2)" 0 0 '"quorum_required": 2' "$out3"
rm -f "$capr"

echo "== ens-review endpoint-id hardening =="
pf="$(mktemp)"; echo "x" > "$pf"
ENSEMBLE_ROSTER="$RM" bash "$ROOT/scripts/ens-review.sh" --reviewers '../../etc/evil@codex' --prompt-file "$pf" >/dev/null 2>&1; rc=$?
check "path-traversal endpoint id rejected -> exit 1" 1 "$rc"
ENSEMBLE_ROSTER="$RM" bash "$ROOT/scripts/ens-review.sh" --reviewers '..' --prompt-file "$pf" >/dev/null 2>&1; rc=$?
check "dotdot endpoint id rejected -> exit 1" 1 "$rc"
ENSEMBLE_ROSTER="$RM" bash "$ROOT/scripts/ens-review.sh" --reviewers '-rf@codex' --prompt-file "$pf" >/dev/null 2>&1; rc=$?
check "leading-dash endpoint id rejected -> exit 1" 1 "$rc"
dup="$(ENSEMBLE_ROSTER="$RM" bash "$ROOT/scripts/ens-review.sh" --reviewers 'a@codex,a@codex,b@codex' --prompt-file "$pf" 2>/dev/null | grep -c '"endpoint": "a@codex"')"
check "duplicate endpoint ids deduped to one" 0 0 "1" "$dup"
rm -f "$pf"

echo "== ens-review read-only (worktree isolation) =="
rotmp="$(mktemp -d)"; ( cd "$rotmp" && git init -q && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init )
cp "$RM" "$rotmp/roster.json"
out="$(cd "$rotmp" && printf hi | ENSEMBLE_ROSTER="$rotmp/roster.json" ENS_TEST_MODES='a@codex=mutate' bash "$ROOT/scripts/ens-review.sh" --reviewers a@codex,b@codex - 2>/dev/null)"; rc=$?
check "read-only violation -> exit 5" 5 "$rc"
check "violation flagged in json" 0 0 '"read_only_violation": true' "$out"
clean="$(cd "$rotmp" && git status --porcelain)"
check "user tree untouched (reviewer wrote only the disposable copy)" 0 0 "" "$clean"
rm -rf "$rotmp"

rotmp2="$(mktemp -d)"; ( cd "$rotmp2" && git init -q && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init )
cp "$RM" "$rotmp2/roster.json"; ( cd "$rotmp2" && echo keep > keep.txt )   # pre-existing untracked
out="$(cd "$rotmp2" && printf hi | ENSEMBLE_ROSTER="$rotmp2/roster.json" ENS_TEST_MODES='a@codex=mutate' bash "$ROOT/scripts/ens-review.sh" --reviewers a@codex,b@codex - 2>/dev/null)"; rc=$?
check "pre-existing untracked preserved (keep.txt)" 0 0 "1" "$([ -f "$rotmp2/keep.txt" ] && echo 1 || echo 0)"
check "reviewer mutation removed (probe gone)" 0 0 "1" "$([ ! -f "$rotmp2/ens_review_mutation_probe.tmp" ] && echo 1 || echo 0)"
check "violation still exit 5 with pre-existing untracked" 5 "$rc"
rm -rf "$rotmp2"

# C1: a reviewer mutation must NOT destroy the user's uncommitted tracked edit
ro3="$(mktemp -d)"; ( cd "$ro3" && git init -q && printf 'orig\n' > f.txt && git add f.txt && git -c user.email=t@t -c user.name=t commit -q -m init && printf 'USER-EDIT\n' > f.txt )
cp "$RM" "$ro3/roster.json"
out="$(cd "$ro3" && printf hi | ENSEMBLE_ROSTER="$ro3/roster.json" ENS_TEST_MODES='a@codex=mutate' bash "$ROOT/scripts/ens-review.sh" --reviewers a@codex,b@codex - 2>/dev/null)"; rc=$?
check "user uncommitted tracked edit preserved" 0 0 "USER-EDIT" "$(cat "$ro3/f.txt")"
check "reviewer untracked file removed" 0 0 "1" "$([ ! -f "$ro3/ens_review_mutation_probe.tmp" ] && echo 1 || echo 0)"
check "untracked violation -> exit 5" 5 "$rc"; rm -rf "$ro3"
# C2: a reviewer overwriting an already-dirty tracked file must be DETECTED and the user's content untouched
ro4="$(mktemp -d)"; ( cd "$ro4" && git init -q && printf 'orig\n' > tracked.txt && git add tracked.txt && git -c user.email=t@t -c user.name=t commit -q -m init && printf 'USER-WIP\n' > tracked.txt )
cp "$RM" "$ro4/roster.json"
out="$(cd "$ro4" && printf hi | ENSEMBLE_ROSTER="$ro4/roster.json" ENS_TEST_MODES='a@codex=mutate_tracked' bash "$ROOT/scripts/ens-review.sh" --reviewers a@codex,b@codex - 2>/dev/null)"; rc=$?
check "content overwrite of dirty tracked file detected -> exit 5" 5 "$rc"
check "user WIP preserved through reviewer overwrite" 0 0 "USER-WIP" "$(cat "$ro4/tracked.txt")"; rm -rf "$ro4"

# Isolation invariant: the user's real tree is NEVER touched, so the prior data-loss residuals are closed.
# T-new-1: overwriting a pre-existing UNTRACKED file is now safe (was the known undetected residual)
ro5="$(mktemp -d)"; ( cd "$ro5" && git init -q && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init && printf 'USER-DATA\n' > data.txt )   # data.txt: pre-existing untracked
cp "$RM" "$ro5/roster.json"
out="$(cd "$ro5" && printf hi | ENSEMBLE_ROSTER="$ro5/roster.json" ENS_TEST_MODES='a@codex=mutate_untracked' bash "$ROOT/scripts/ens-review.sh" --reviewers a@codex,b@codex - 2>/dev/null)"; rc=$?
check "pre-existing untracked content preserved (residual closed)" 0 0 "USER-DATA" "$(cat "$ro5/data.txt")"
check "untracked-overwrite attempt still flagged -> exit 5" 5 "$rc"; rm -rf "$ro5"

# T-new-2: a clean reviewer run with pre-existing untracked files must NOT false-positive to exit 5
ro6="$(mktemp -d)"; ( cd "$ro6" && git init -q && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init && printf 'junk\n' > junk.txt )   # pre-existing untracked, no mutation
cp "$RM" "$ro6/roster.json"
out="$(cd "$ro6" && printf hi | ENSEMBLE_ROSTER="$ro6/roster.json" bash "$ROOT/scripts/ens-review.sh" --reviewers a@codex,b@codex - 2>/dev/null)"; rc=$?
check "no false read-only violation with pre-existing untracked -> exit 0" 0 "$rc"
check "clean run leaves pre-existing untracked untouched" 0 0 "junk" "$(cat "$ro6/junk.txt")"; rm -rf "$ro6"

# T-new-3: a .gitignore'd file and the overall real tree survive a mutating reviewer untouched
ro7="$(mktemp -d)"; ( cd "$ro7" && git init -q && printf '*.log\n' > .gitignore && git add .gitignore && git -c user.email=t@t -c user.name=t commit -q -m init && printf 'SECRET\n' > secret.log )   # secret.log: ignored
cp "$RM" "$ro7/roster.json"
before="$(cd "$ro7" && git status --porcelain)"
out="$(cd "$ro7" && printf hi | ENSEMBLE_ROSTER="$ro7/roster.json" ENS_TEST_MODES='a@codex=mutate' bash "$ROOT/scripts/ens-review.sh" --reviewers a@codex,b@codex - 2>/dev/null)"; rc=$?
check "ignored file preserved through mutating reviewer" 0 0 "SECRET" "$(cat "$ro7/secret.log")"
after="$(cd "$ro7" && git status --porcelain)"
check "real tree status unchanged after mutating reviewer" 0 "$([ "$before" = "$after" ] && echo 0 || echo 1)"; rm -rf "$ro7"

echo "== ens-review isolation failure / fallback =="
# T-new-4: inside a git repo where worktree creation fails (unborn HEAD), FAIL CLOSED -> die, never run unguarded
ro8="$(mktemp -d)"; ( cd "$ro8" && git init -q )   # no commit -> HEAD unborn -> `git worktree add HEAD` fails
cp "$RM" "$ro8/roster.json"
out="$(cd "$ro8" && printf hi | ENSEMBLE_ROSTER="$ro8/roster.json" ENS_TEST_MODES='a@codex=mutate' bash "$ROOT/scripts/ens-review.sh" --reviewers a@codex,b@codex - 2>/dev/null)"; rc=$?
check "worktree-add failure fails closed -> exit 1 (die)" 1 "$rc"
check "no reviewer ran in real tree on isolation failure (probe absent)" 0 0 "1" "$([ ! -f "$ro8/ens_review_mutation_probe.tmp" ] && echo 1 || echo 0)"
rm -rf "$ro8"

# T-new-5: outside any git repo, isolation is impossible -> run unguarded but flag it (not a silent bypass)
ng="$(mktemp -d)"   # NOT a git repo
cp "$RM" "$ng/roster.json"
out="$(cd "$ng" && printf hi | ENSEMBLE_ROSTER="$ng/roster.json" bash "$ROOT/scripts/ens-review.sh" --reviewers a@codex,b@codex - 2>/dev/null)"; rc=$?
check "non-git dir flagged read_only_guarded:false" 0 0 '"read_only_guarded": false' "$out"
check "non-git dir still reaches quorum -> exit 0" 0 "$rc"
rm -rf "$ng"

# T-new-6: uncommitted tracked WIP is replayed into the review copy (faithful context) and signalled
ro9="$(mktemp -d)"; ( cd "$ro9" && git init -q && printf 'v1\n' > a.txt && git add a.txt && git -c user.email=t@t -c user.name=t commit -q -m init && printf 'v2-uncommitted\n' > a.txt )
cp "$RM" "$ro9/roster.json"
out="$(cd "$ro9" && printf hi | ENSEMBLE_ROSTER="$ro9/roster.json" bash "$ROOT/scripts/ens-review.sh" --reviewers a@codex,b@codex - 2>/dev/null)"; rc=$?
check "uncommitted tracked WIP replayed into review copy" 0 0 '"wip_replayed": "yes"' "$out"
check "WIP review run reaches quorum -> exit 0" 0 "$rc"
check "WIP review left user tree untouched" 0 0 "v2-uncommitted" "$(cat "$ro9/a.txt")"; rm -rf "$ro9"

echo "== ens-council (two-round de-biased review) =="
cot="$(mktemp -d)"; ( cd "$cot" && git init -q && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init )
cp "$RM" "$cot/roster.json"
# happy path: 3 ok reviewers -> round1 + anonymized peer round2 + de-anon map
out="$(cd "$cot" && printf 'review this' | ENSEMBLE_ROSTER="$cot/roster.json" bash "$ROOT/scripts/ens-council.sh" --reviewers a@codex,b@codex,c@codex - 2>/dev/null)"; rc=$?
check "council exit 0" 0 "$rc"
check "council mode tag" 0 0 '"mode": "council"' "$out"
check "council emits round1" 0 0 '"round1"' "$out"
check "council anon map labels reviewers" 0 0 '"A":' "$out"
r2state="$(printf '%s' "$out" | python3 -c 'import sys,json;print("present" if json.load(sys.stdin)["round2"] else "null")')"
check "council convened a peer round (round2 present)" 0 0 "present" "$r2state"
nr2="$(printf '%s' "$out" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(len(d["round2"]["reviewers"]) if d["round2"] else 0)')"
check "council peer round re-ran the OK reviewers (3)" 0 0 "3" "$nr2"
# below quorum: only 1 OK reviewer -> council not convened, exit 4, round2 null
out2="$(cd "$cot" && printf 'review' | ENSEMBLE_ROSTER="$cot/roster.json" ENS_TEST_MODES='b@codex=auth,c@codex=auth' bash "$ROOT/scripts/ens-council.sh" --reviewers a@codex,b@codex,c@codex - 2>/dev/null)"; rc2=$?
check "council below 2 reviewers -> exit 4" 4 "$rc2"
r2n2="$(printf '%s' "$out2" | python3 -c 'import sys,json;print("null" if json.load(sys.stdin)["round2"] is None else "present")')"
check "council not convened -> round2 null" 0 0 "null" "$r2n2"
rm -rf "$cot"
# a reviewer mutation in round 1 propagates read-only violation -> exit 5
cot2="$(mktemp -d)"; ( cd "$cot2" && git init -q && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init )
cp "$RM" "$cot2/roster.json"
out3="$(cd "$cot2" && printf 'review' | ENSEMBLE_ROSTER="$cot2/roster.json" ENS_TEST_MODES='a@codex=mutate' bash "$ROOT/scripts/ens-council.sh" --reviewers a@codex,b@codex - 2>/dev/null)"; rc3=$?
check "council read-only violation -> exit 5" 5 "$rc3"
check "council read-only still emits council wrapper (not bare ens-review json)" 0 0 '"mode": "council"' "$out3"
rm -rf "$cot2"
# identity scrub: a reviewer self-identifying in prose must be scrubbed from the peer block
cot3="$(mktemp -d)"; ( cd "$cot3" && git init -q && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init )
dbg="$(mktemp -d)"
( cd "$cot3" && printf 'review this' | ENS_COUNCIL_DEBUG_DIR="$dbg" ENSEMBLE_ROSTER="$ROOT/roster.json" STUB_MODE=ok bash "$ROOT/scripts/ens-council.sh" --reviewers grok-build@grok,mistral-medium-3.5@vibe - >/dev/null 2>&1 )
check "council exposes peer block for inspection" 0 0 "1" "$([ -f "$dbg/peer.txt" ] && echo 1 || echo 0)"
# the vibe stub emits 'from vibe (model: mistral-medium-3.5)'; both identity tokens must be scrubbed
check "council scrubbed model name 'vibe' from peer block" 0 "$(grep -qi 'vibe' "$dbg/peer.txt" && echo 1 || echo 0)"
check "council scrubbed family 'mistral' from peer block" 0 "$(grep -qi 'mistral' "$dbg/peer.txt" && echo 1 || echo 0)"
check "council peer block uses anonymized labels" 0 0 "REVIEW A" "$(cat "$dbg/peer.txt" 2>/dev/null)"
# generic words that are sub-tokens of model ids (build/medium/pro) must SURVIVE (no over-scrub)
check "council kept generic word 'medium' (not over-scrubbed)" 0 0 "medium" "$(cat "$dbg/peer.txt" 2>/dev/null)"
check "council kept generic word 'build'" 0 0 "build" "$(cat "$dbg/peer.txt" 2>/dev/null)"
check "council kept generic word 'pro'" 0 0 "pro" "$(cat "$dbg/peer.txt" 2>/dev/null)"
rm -rf "$cot3" "$dbg"

echo "== ens_executors selection =="
ex="$(ens_executors "$ROOT/tests/fixtures/roster-multi.json" | cut -f1 | tr '\n' ' ')"
check "ens_executors lists role=both (b@codex)" 0 0 "b@codex" "$ex"
check "ens_executors lists role=executor (x@codex)" 0 0 "x@codex" "$ex"
check "ens_executors excludes reviewer-only (a@codex)" 0 "$(printf '%s' "$ex" | grep -qw 'a@codex' && echo 1 || echo 0)"
check "ens_executors excludes disabled (off@codex)" 0 "$(printf '%s' "$ex" | grep -q 'off@codex' && echo 1 || echo 0)"

echo "== model-cli run (executor write mode) =="
rundir="$(mktemp -d)"; pf="$(mktemp)"; echo "create a thing" > "$pf"
out="$(STUB_MODE=ok bash "$ROOT/scripts/model-cli.sh" run --endpoint gpt-5.5@codex --prompt-file "$pf" --dir "$rundir" 2>/dev/null)"; rc=$?
check "model-cli run rc 0" 0 "$rc"
check "model-cli run emits digest" 0 0 '===DIGEST===' "$out"
check "executor wrote a file in --dir" 0 0 "1" "$([ -f "$rundir/ens_delegate_stub.txt" ] && echo 1 || echo 0)"
STUB_MODE=ok bash "$ROOT/scripts/model-cli.sh" run --endpoint gpt-5.5@codex --prompt-file "$pf" >/dev/null 2>&1; rc=$?
check "run without --dir -> exit 1" 1 "$rc"
STUB_MODE=ok bash "$ROOT/scripts/model-cli.sh" run --endpoint mistral-medium-3.5@vibe --prompt-file "$pf" --dir "$rundir" >/dev/null 2>&1; rc=$?
check "run on reviewer-only endpoint -> exit 1" 1 "$rc"
rc=0; STUB_MODE=auth bash "$ROOT/scripts/model-cli.sh" run --endpoint gpt-5.5@codex --prompt-file "$pf" --dir "$rundir" >/dev/null 2>&1 || rc=$?
check "run auth -> exit 11" 11 "$rc"
rm -rf "$rundir"; rm -f "$pf"
# every executor adapter (write mode) -> digest + a file written inside --dir; auth -> 11
for ep in gemini-3.5-flash@agy grok-build@grok deepseek-v4-pro@opencode glm-5.2@kilo; do
  rd="$(mktemp -d)"; pf2="$(mktemp)"; echo "implement the unit" > "$pf2"
  out="$(STUB_MODE=ok bash "$ROOT/scripts/model-cli.sh" run --endpoint "$ep" --prompt-file "$pf2" --dir "$rd" 2>/dev/null)"; rc=$?
  check "model-cli run $ep -> rc 0" 0 "$rc"
  check "model-cli run $ep emits digest" 0 0 '===DIGEST===' "$out"
  check "model-cli run $ep wrote file in --dir" 0 0 "1" "$([ -f "$rd/ens_delegate_stub.txt" ] && echo 1 || echo 0)"
  rc=0; STUB_MODE=auth bash "$ROOT/scripts/model-cli.sh" run --endpoint "$ep" --prompt-file "$pf2" --dir "$rd" >/dev/null 2>&1 || rc=$?
  check "model-cli run $ep auth -> exit 11" 11 "$rc"
  rm -rf "$rd"; rm -f "$pf2"
done

echo "== ens-delegate (worktree run/merge/discard) =="
dg="$(mktemp -d)"; ( cd "$dg" && git init -q && printf 'base\n' > base.txt && git add base.txt && git -c user.email=t@t -c user.name=t commit -q -m init )
cp "$RM" "$dg/roster.json"; pf="$(mktemp)"; echo "implement the unit" > "$pf"
out="$(cd "$dg" && STUB_MODE=ok ENSEMBLE_ROSTER="$dg/roster.json" bash "$ROOT/scripts/ens-delegate.sh" run --endpoint x@codex --prompt-file "$pf" 2>/dev/null)"; rc=$?
check "delegate run rc 0" 0 "$rc"
check "delegate run emits digest" 0 0 '===DIGEST===' "$out"
check "delegate run lists files_changed" 0 0 'ens_delegate_stub.txt' "$out"
WT="$(printf '%s' "$out" | python3 -c 'import json,sys;print(json.load(sys.stdin)["worktree"])')"
check "delegate worktree left in place for verify" 0 0 "1" "$([ -d "$WT" ] && echo 1 || echo 0)"
check "executor write isolated to worktree (not main repo)" 0 0 "1" "$([ ! -f "$dg/ens_delegate_stub.txt" ] && echo 1 || echo 0)"
( cd "$dg" && STUB_MODE=ok ENSEMBLE_ROSTER="$dg/roster.json" bash "$ROOT/scripts/ens-delegate.sh" merge --worktree "$WT" >/dev/null 2>&1 )
check "delegate merge brought file into main repo" 0 0 "1" "$([ -f "$dg/ens_delegate_stub.txt" ] && echo 1 || echo 0)"
check "delegate merge removed the worktree" 0 0 "1" "$([ ! -d "$WT" ] && echo 1 || echo 0)"
out2="$(cd "$dg" && STUB_MODE=ok ENSEMBLE_ROSTER="$dg/roster.json" bash "$ROOT/scripts/ens-delegate.sh" run --endpoint x@codex --prompt-file "$pf" 2>/dev/null)"
WT2="$(printf '%s' "$out2" | python3 -c 'import json,sys;print(json.load(sys.stdin)["worktree"])')"
( cd "$dg" && bash "$ROOT/scripts/ens-delegate.sh" discard --worktree "$WT2" >/dev/null 2>&1 )
check "delegate discard removed the worktree" 0 0 "1" "$([ ! -d "$WT2" ] && echo 1 || echo 0)"
check "delegate discard left no uncommitted tracked changes" 0 "$(cd "$dg" && git status --porcelain | grep -v '^??' | grep -q . && echo 1 || echo 0)"
rm -rf "$dg"; rm -f "$pf"
# PROVENANCE GUARD: merge/discard must refuse a worktree that is not an ensemble/delegate-* branch
pg="$(mktemp -d)"; ( cd "$pg" && git init -q && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init && git worktree add -q -b my-feature "$pg/feat" HEAD )
rc=0; ( cd "$pg" && bash "$ROOT/scripts/ens-delegate.sh" discard --worktree "$pg/feat" >/dev/null 2>&1 ) || rc=$?
check "discard refuses a non-delegate worktree -> exit 1" 1 "$rc"
check "non-delegate worktree survived the refused discard" 0 0 "1" "$([ -d "$pg/feat" ] && echo 1 || echo 0)"
check "user's branch survived the refused discard" 0 0 "my-feature" "$(cd "$pg" && git branch --list my-feature)"
rc=0; ( cd "$pg" && bash "$ROOT/scripts/ens-delegate.sh" merge --worktree "$pg/feat" >/dev/null 2>&1 ) || rc=$?
check "merge refuses a non-delegate worktree -> exit 1" 1 "$rc"
( cd "$pg" && git worktree remove --force "$pg/feat" 2>/dev/null ); rm -rf "$pg"

echo "== review surface contract =="
python3 - "$ROOT" <<'PY'; rc=$?
import os,sys
root=sys.argv[1]; errs=[]
for f in ("skills/multi-model-review/SKILL.md","commands/review.md"):
    p=os.path.join(root,f)
    if not os.path.isfile(p): errs.append("missing "+f); continue
    t=open(p).read()
    if not (t.startswith("---") and t.count("---")>=2): errs.append("no frontmatter: "+f)
skill_txt=open(os.path.join(root,"skills/multi-model-review/SKILL.md")).read()
if "ens-review.sh" not in skill_txt:
    errs.append("skill does not reference ens-review.sh")
if "ens-council.sh" not in skill_txt:
    errs.append("skill does not document council mode (ens-council.sh)")
for s in ("scripts/ens-review.sh","scripts/ens-council.sh"):
    if not os.access(os.path.join(root,s), os.X_OK):
        errs.append(s+" not executable")
if errs:
    [print("  -",e) for e in errs]; sys.exit(1)
PY
check "review surface contract holds" 0 "$rc"

echo "== delegate surface contract =="
python3 - "$ROOT" <<'PY'; rc=$?
import os,sys
root=sys.argv[1]; errs=[]
for f in ("skills/delegate-implementation/SKILL.md","commands/delegate.md","agents/ensemble-delegate.md"):
    p=os.path.join(root,f)
    if not os.path.isfile(p): errs.append("missing "+f); continue
    t=open(p).read()
    if not (t.startswith("---") and t.count("---")>=2): errs.append("no frontmatter: "+f)
skill=open(os.path.join(root,"skills/delegate-implementation/SKILL.md")).read()
if "ens-delegate.sh" not in skill: errs.append("delegate skill does not reference ens-delegate.sh")
agent=open(os.path.join(root,"agents/ensemble-delegate.md")).read()
# the constrained subagent must NOT grant Write/Edit (worktree is the file-acting path)
import re
m=re.search(r'(?m)^tools:\s*(.+)$', agent)
if not m: errs.append("subagent missing tools: allowlist")
elif ("Write" in m.group(1)) or ("Edit" in m.group(1)): errs.append("subagent must not allow Write/Edit")
if not os.access(os.path.join(root,"scripts/ens-delegate.sh"), os.X_OK): errs.append("ens-delegate.sh not executable")
if errs:
    [print("  -",e) for e in errs]; sys.exit(1)
PY
check "delegate surface contract holds" 0 "$rc"

echo "== ens-setup: family normalization =="
check "family deepseek (router id)" 0 0 "deepseek" "$(bash "$ROOT/scripts/ens-setup.sh" family 'opencode-go/deepseek-v4-pro')"
check "family google (agy display name)" 0 0 "google" "$(bash "$ROOT/scripts/ens-setup.sh" family 'Gemini 3.5 Flash (Medium)')"
check "family zai (kilo glm)" 0 0 "zai" "$(bash "$ROOT/scripts/ens-setup.sh" family 'kilo/z-ai/glm-5.2')"
check "family openai (bare gpt)" 0 0 "openai" "$(bash "$ROOT/scripts/ens-setup.sh" family 'gpt-5.5')"
check "family anthropic (cross-router)" 0 0 "anthropic" "$(bash "$ROOT/scripts/ens-setup.sh" family 'cloudflare-ai-gateway/anthropic/claude-opus-4-6')"
check "family unknown (no vendor token)" 0 0 "unknown" "$(bash "$ROOT/scripts/ens-setup.sh" family 'zzz-private-model-9')"

echo "== ens-setup: idfor (engine-safe ids) =="
check "idfor strips router slash" 0 0 "deepseek-v4-pro@opencode" "$(bash "$ROOT/scripts/ens-setup.sh" idfor 'opencode-go/deepseek-v4-pro' opencode)"
check "idfor sanitizes spaces/parens" 0 0 "gemini-3.5-flash-medium@agy" "$(bash "$ROOT/scripts/ens-setup.sh" idfor 'Gemini 3.5 Flash (Medium)' agy)"
idtest="$(bash "$ROOT/scripts/ens-setup.sh" idfor 'kilo/z-ai/glm-5.2' kilo)"
check "idfor output is engine-safe" 0 "$(printf '%s' "$idtest" | grep -qE '^[A-Za-z0-9._@-]+$' && echo 0 || echo 1)"

echo "== ens-setup: defaults + validate =="
check "defaults seeds strengths" 0 0 "repo-reasoning" "$(bash "$ROOT/scripts/ens-setup.sh" defaults 'gpt-5.5')"
check "defaults resolves sub-brand via family (devstral->mistral)" 0 0 "security-crypto" "$(bash "$ROOT/scripts/ens-setup.sh" defaults 'devstral-small')"
bash "$ROOT/scripts/ens-setup.sh" validate "$ROOT/roster.json" >/dev/null 2>&1; check "validate accepts shipped roster -> 0" 0 "$?"
# reject paths: vibe-as-executor, bad effort, slashed (engine-unsafe) id, missing model, wrong structured_output pairing
for bad in \
 '{"endpoints":[{"id":"m@vibe","adapter":"vibe","model":"mistral-medium-3.5","family":"mistral","effort":"medium","role":"executor","structured_output":"sentinel","enabled":true}]}' \
 '{"endpoints":[{"id":"x@codex","adapter":"codex","model":"gpt-5.5","family":"openai","effort":"bogus","role":"reviewer","structured_output":"json","enabled":true}]}' \
 '{"endpoints":[{"id":"deepseek/v4@opencode","adapter":"opencode","model":"opencode-go/deepseek-v4-pro","family":"deepseek","effort":"medium","role":"reviewer","structured_output":"sentinel","enabled":true}]}' \
 '{"endpoints":[{"id":"a..b@codex","adapter":"codex","model":"gpt-5.5","family":"openai","effort":"medium","role":"reviewer","structured_output":"json","enabled":true}]}' \
 '{"endpoints":[{"id":"x@codex","adapter":"codex","family":"openai","effort":"medium","role":"reviewer","structured_output":"json","enabled":true}]}' \
 '{"endpoints":[{"id":"x@codex","adapter":"codex","model":"gpt-5.5","family":"openai","effort":"medium","role":"reviewer","structured_output":"sentinel","enabled":true}]}' ; do
  bf="$(mktemp)"; printf '%s' "$bad" > "$bf"; bash "$ROOT/scripts/ens-setup.sh" validate "$bf" >/dev/null 2>&1; check "validate rejects bad roster -> 1" 1 "$?"; rm -f "$bf"
done

echo "== ens-setup: detect (stubs) =="
det="$(PATH="$ROOT/tests/stubs:$PATH" ENS_VIBE_CONFIG="$ROOT/tests/fixtures/vibe-config.toml" STUB_MODE=ok bash "$ROOT/scripts/ens-setup.sh" detect)"
check "detect lists all six transports" 0 0 '"adapter": "vibe"' "$det"
check "detect marks codex executor_capable" 0 0 '"executor_capable": true' "$det"
check "detect marks vibe reviewer-only" 0 0 '"default_role": "reviewer"' "$det"

echo "== roster path resolution =="
( ENSEMBLE_ROSTER=/x/y.json; unset CLAUDE_PLUGIN_DATA; source "$ROOT/scripts/lib/roster-path.sh"; [ "$ROSTER" = "/x/y.json" ] ) && { echo "ok: ENSEMBLE_ROSTER wins"; PASS=$((PASS+1)); } || { echo "FAIL: ENSEMBLE_ROSTER precedence"; FAIL=$((FAIL+1)); }
pdata="$(mktemp -d)"; cp "$ROOT/roster.json" "$pdata/roster.json"
( unset ENSEMBLE_ROSTER; CLAUDE_PLUGIN_DATA="$pdata"; source "$ROOT/scripts/lib/roster-path.sh"; [ "$ROSTER" = "$pdata/roster.json" ] ) && { echo "ok: CLAUDE_PLUGIN_DATA preferred"; PASS=$((PASS+1)); } || { echo "FAIL: CLAUDE_PLUGIN_DATA precedence"; FAIL=$((FAIL+1)); }
( unset ENSEMBLE_ROSTER; unset CLAUDE_PLUGIN_DATA; source "$ROOT/scripts/lib/roster-path.sh"; [ "$ROSTER" = "$ROOT/roster.json" ] ) && { echo "ok: falls back to shipped roster"; PASS=$((PASS+1)); } || { echo "FAIL: shipped fallback"; FAIL=$((FAIL+1)); }
rm -rf "$pdata"

echo "== setup surface contract =="
python3 - "$ROOT" <<'PY'; rc=$?
import os,sys,json
root=sys.argv[1]; errs=[]
for f in ("skills/ensemble-setup/SKILL.md","commands/setup.md"):
    p=os.path.join(root,f)
    if not os.path.isfile(p): errs.append("missing "+f); continue
    t=open(p).read()
    if not (t.startswith("---") and t.count("---")>=2): errs.append("no frontmatter: "+f)
    if "ens-setup.sh" not in t: errs.append(f+" does not reference ens-setup.sh")
if not os.access(os.path.join(root,"scripts/ens-setup.sh"), os.X_OK): errs.append("ens-setup.sh not executable")
try: json.load(open(os.path.join(root,"data/model-defaults.json")))
except Exception as e: errs.append("model-defaults.json invalid: %s"%e)
if errs:
    [print("  -",e) for e in errs]; sys.exit(1)
PY
check "setup surface contract holds" 0 "$rc"

echo "== gating hooks (§8) =="
# SessionStart: emits the 3-gate policy + configured reviewers; honors the toggle
ss="$(echo '{"source":"startup"}' | ENSEMBLE_ROSTER="$ROOT/roster.json" bash "$ROOT/hooks/session-start.sh")"
check "session-start emits additionalContext" 0 0 '"hookEventName": "SessionStart"' "$ss"
check "session-start mentions /ensemble:review" 0 0 '/ensemble:review' "$ss"
check "session-start lists a configured reviewer" 0 0 'gpt-5.5@codex' "$ss"
ssoff="$(echo '{}' | ENSEMBLE_GATE_REMINDERS=0 bash "$ROOT/hooks/session-start.sh")"
check "session-start toggled off -> silent" 0 0 "0" "${#ssoff}"
# PostToolUse: nudges only on spec/plan/design paths
pw_spec="$(echo '{"tool_name":"Write","tool_input":{"file_path":"/r/docs/specs/x-design.md"}}' | bash "$ROOT/hooks/post-write.sh")"
check "post-write nudges on a spec path" 0 0 '/ensemble:review' "$pw_spec"
pw_plan="$(echo '{"tool_input":{"file_path":"/r/notes/feature-plan.md"}}' | bash "$ROOT/hooks/post-write.sh")"
check "post-write nudges on a *plan*.md basename" 0 0 'hookEventName' "$pw_plan"
pw_code="$(echo '{"tool_input":{"file_path":"/r/src/main.py"}}' | bash "$ROOT/hooks/post-write.sh")"
check "post-write silent on a code file" 0 0 "0" "${#pw_code}"
pw_off="$(echo '{"tool_input":{"file_path":"/r/docs/specs/x.md"}}' | ENSEMBLE_GATE_REMINDERS=0 bash "$ROOT/hooks/post-write.sh")"
check "post-write toggled off -> silent" 0 0 "0" "${#pw_off}"
pw_glob="$(echo '{"tool_input":{"file_path":"/r/RFC-1.txt"}}' | ENSEMBLE_GATE_GLOBS='*RFC*' bash "$ROOT/hooks/post-write.sh")"
check "post-write honors custom globs" 0 0 'hookEventName' "$pw_glob"
pw_bad="$(printf 'not json' | bash "$ROOT/hooks/post-write.sh")"; rc=$?
check "post-write survives garbage stdin -> rc 0, silent" 0 "$rc"
check "post-write garbage -> no output" 0 0 "0" "${#pw_bad}"

echo "== hooks surface contract =="
python3 - "$ROOT" <<'PY'; rc=$?
import os,sys,json
root=sys.argv[1]; errs=[]
hp=os.path.join(root,"hooks","hooks.json")
if not os.path.isfile(hp): errs.append("missing hooks/hooks.json")
else:
    try: h=json.load(open(hp))
    except Exception as e: errs.append("hooks.json invalid: %s"%e); h={}
    hk=(h or {}).get("hooks",{})
    if "SessionStart" not in hk: errs.append("no SessionStart hook")
    pt=hk.get("PostToolUse",[])
    if not any(m.get("matcher")=="Write|Edit" for m in pt if isinstance(m,dict)): errs.append("no PostToolUse Write|Edit matcher")
    blob=json.dumps(h)
    for s in ("session-start.sh","post-write.sh"):
        if s not in blob: errs.append("hooks.json does not wire "+s)
for s in ("hooks/session-start.sh","hooks/post-write.sh"):
    if not os.access(os.path.join(root,s), os.X_OK): errs.append(s+" not executable")
if errs:
    [print("  -",e) for e in errs]; sys.exit(1)
PY
check "hooks surface contract holds" 0 "$rc"

echo ""; echo "PASS=$PASS FAIL=$FAIL"; [ "$FAIL" -eq 0 ]
