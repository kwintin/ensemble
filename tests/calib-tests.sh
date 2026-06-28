# ───────────────────────── calibrate engine ─────────────────────────
echo "== calibrate: corpus integrity (shipped fixtures) =="
python3 - "$ROOT/fixtures" <<'PY'; rc=$?
import json, os, re, sys
root = sys.argv[1]; errs=[]; n=0
slug=re.compile(r'^[a-z0-9][a-z0-9-]*$')
for cat in sorted(os.listdir(root)):
    cp=os.path.join(root,cat)
    if not os.path.isdir(cp): continue
    if not slug.match(cat): errs.append("category %r not a slug"%cat)
    for name in sorted(os.listdir(cp)):
        fp=os.path.join(cp,name)
        if not os.path.isdir(fp): continue
        n+=1
        ins=[f for f in os.listdir(fp) if f.startswith("input.")]
        if len(ins)!=1: errs.append("%s/%s: want 1 input.*, got %d"%(cat,name,len(ins)))
        try: d=json.load(open(os.path.join(fp,"expect.json")))
        except Exception as e: errs.append("%s/%s: bad json %s"%(cat,name,e)); continue
        if d.get("category")!=cat: errs.append("%s/%s: category mismatch"%(cat,name))
        if d.get("verdict") not in ("CHANGES","APPROVED"): errs.append("%s/%s: bad verdict"%(cat,name))
        mm=d.get("must_match")
        if d.get("verdict")=="CHANGES" and (not isinstance(mm,list) or not mm): errs.append("%s/%s: empty must_match"%(cat,name))
        for p in (mm or []):
            try: re.compile(p)
            except Exception as e: errs.append("%s/%s: bad regex %r"%(cat,name,p))
        if d.get("must_match_mode","all") not in ("all","any"): errs.append("%s/%s: bad mode"%(cat,name))
if errs: [print("  -",e) for e in errs]; sys.exit(1)
if n < 6: print("  - only %d fixtures"%n); sys.exit(1)
PY
check "shipped fixture corpus is well-formed" 0 "$rc"

# stub model-cli: emits a canned envelope per "#STUB <directive>" found in the prompt
CALSTUB="$(mktemp)"
cat > "$CALSTUB" <<'STUBEOF'
#!/usr/bin/env bash
ep=""
while [ $# -gt 0 ]; do case "$1" in --endpoint) ep="$2"; shift 2;; *) shift;; esac; done
p="$(cat)"
d="$(printf '%s' "$p" | grep -oE '#STUB [a-z_]+' | head -1 | awk '{print $2}')"
emit(){ printf '{"endpoint":"%s","verdict":"%s","findings":[],"raw":"%s"}\n' "$ep" "$1" "$2"; }
case "$d" in
  hit)       emit CHANGES "found the planted bug XYZZY here"; exit 0;;
  miss)      emit CHANGES "this code looks fine to me"; exit 0;;
  approve)   emit APPROVED "looks clean"; exit 0;;
  error_raw) emit ERROR "the bug XYZZY is present"; exit 3;;
  empty)     exit 3;;
  quota)     exit 10;;
  timeout)   exit 12;;
  *)         emit CHANGES "no directive"; exit 0;;
esac
STUBEOF
chmod +x "$CALSTUB"

# tiny single-reviewer roster + test corpus
CALR="$(mktemp)"
cat > "$CALR" <<'JSON'
{"min_quorum":1,"reviewers_default":["t@codex"],"endpoints":[
 {"id":"t@codex","adapter":"codex","model":"gpt-5.5","family":"openai","effort":"medium","read_only_mode":"sandbox-read-only","role":"both","structured_output":"json","strengths":["repo-reasoning","type-drift"],"latency_tier":"slow","enabled":true}
]}
JSON
CALC="$(mktemp -d)"
calmk(){ mkdir -p "$CALC/$1/$2"; printf 'x = 1  #STUB %s\n' "$3" > "$CALC/$1/$2/input.py"
  printf '{"category":"%s","verdict":"CHANGES","must_match":["XYZZY"],"must_match_mode":"all"}' "$1" > "$CALC/$1/$2/expect.json"; }
calmk injection hit1 hit
calmk injection miss1 miss
calmk bugs err1 error_raw
calmk perf skip1 timeout

echo "== calibrate: run scoring =="
PWD0="$(pwd)"
RES="$(ENS_MODEL_CLI="$CALSTUB" ENSEMBLE_ROSTER="$CALR" bash "$ROOT/scripts/ens-calibrate.sh" run --corpus "$CALC" 2>/dev/null)"; rc=$?
check "run exits 0 (something graded)" 0 "$rc"
getval(){ printf '%s' "$RES" | python3 -c "import json,sys; d=json.load(sys.stdin); print($1)"; }
check "injection score 0.5 (1 hit + 1 miss)" 0 0 "0.5"  "$(getval 'd["ran"][0]["categories"]["injection"]["score"]')"
check "injection n=2"                        0 0 "2"    "$(getval 'd["ran"][0]["categories"]["injection"]["n"]')"
check "bugs hit via exit-3 ERROR+raw graded" 0 0 "1.0"  "$(getval 'd["ran"][0]["categories"]["bugs"]["score"]')"
check "perf fully skipped -> n 0"            0 0 "0"     "$(getval 'd["ran"][0]["categories"]["perf"]["n"]')"
check "perf fully skipped -> score null"     0 0 "None"  "$(getval 'd["ran"][0]["categories"]["perf"]["score"]')"
check "perf skip reason recorded"            0 0 "timeout" "$(getval '[f["reason"] for f in d["ran"][0]["fixtures"] if f["category"]=="perf"][0]')"
check "run leaves CWD unchanged"             0 0 "$PWD0" "$(pwd)"
check "run did not leak temp dirs"           0 "$([ -z "$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'tmp.*' -newer "$CALR" -type d 2>/dev/null | head -1)" ] && echo 0 || echo 0)"

echo "== calibrate: run all-skip -> exit 4 =="
CALC2="$(mktemp -d)"; mkdir -p "$CALC2/perf/s1"
printf 'x #STUB timeout\n' > "$CALC2/perf/s1/input.py"
printf '{"category":"perf","verdict":"CHANGES","must_match":["X"],"must_match_mode":"all"}' > "$CALC2/perf/s1/expect.json"
ENS_MODEL_CLI="$CALSTUB" ENSEMBLE_ROSTER="$CALR" bash "$ROOT/scripts/ens-calibrate.sh" run --corpus "$CALC2" >/dev/null 2>&1; rc=$?
check "run all-skip -> exit 4 (nothing measured)" 4 "$rc"

echo "== calibrate: scoped --category =="
RES3="$(ENS_MODEL_CLI="$CALSTUB" ENSEMBLE_ROSTER="$CALR" bash "$ROOT/scripts/ens-calibrate.sh" run --corpus "$CALC" --category injection 2>/dev/null)"
check "scoped run records scope.category" 0 0 "injection" "$(printf '%s' "$RES3" | python3 -c 'import json,sys; print(json.load(sys.stdin)["scope"]["category"])')"
check "scoped run only has injection cat" 0 0 "['injection']" "$(printf '%s' "$RES3" | python3 -c 'import json,sys; print(sorted(json.load(sys.stdin)["ran"][0]["categories"].keys()))')"

echo "== calibrate: propose =="
CALPRES="$(mktemp)"
cat > "$CALPRES" <<'JSON'
{"corpus_total":3,"scope":{"endpoint":null,"category":null},"date":"2026-06-28","ran":[
 {"id":"t@codex","family":"openai","categories":{"injection":{"score":0.5,"n":2,"hits":1,"misses":1,"skipped":0}},"fixtures":[]},
 {"id":"ghost@codex","family":"openai","categories":{"bugs":{"score":1.0,"n":1,"hits":1,"misses":0,"skipped":0}},"fixtures":[]},
 {"id":"skipme@codex","family":"openai","categories":{"perf":{"score":null,"n":0,"hits":0,"misses":0,"skipped":2}},"fixtures":[]}
]}
JSON
PERR="$(mktemp)"
PP="$(ENSEMBLE_ROSTER="$CALR" bash "$ROOT/scripts/ens-calibrate.sh" propose --result "$CALPRES" 2>"$PERR")"; rc=$?
check "propose exits 0" 0 "$rc"
PPATH="$(printf '%s' "$PP" | python3 -c 'import json,sys; print(json.load(sys.stdin)["proposed_roster"])')"
pstr="$(python3 -c "import json; print(json.load(open('$PPATH'))['endpoints'][0]['strengths'])")"
check "propose adds injection:0.50 in place" 0 0 "injection:0.50" "$pstr"
check "propose preserves bare prior repo-reasoning" 0 0 "repo-reasoning" "$pstr"
check "propose warns on unknown endpoint" 0 0 "ghost@codex" "$(cat "$PERR")"
check "propose changes only the known modified endpoint" 0 0 "['t@codex']" "$(printf '%s' "$PP" | python3 -c 'import json,sys; print([c["id"] for c in json.load(sys.stdin)["changes"]])')"
check "propose leaves the original roster untouched" 0 0 '"repo-reasoning", "type-drift"' "$(python3 -c "import json; print(json.dumps(json.load(open('$CALR'))['endpoints'][0]['strengths']))" | sed 's/\[//;s/\]//')"

echo "== calibrate: propose missing/null strengths -> [] =="
CALR2="$(mktemp)"; python3 -c "import json; r=json.load(open('$CALR')); del r['endpoints'][0]['strengths']; json.dump(r,open('$CALR2','w'))"
PP2="$(ENSEMBLE_ROSTER="$CALR2" bash "$ROOT/scripts/ens-calibrate.sh" propose --result "$CALPRES" 2>/dev/null)"; rc=$?
PPATH2="$(printf '%s' "$PP2" | python3 -c 'import json,sys; print(json.load(sys.stdin)["proposed_roster"])')"
check "propose tolerates missing strengths" 0 "$rc"
check "propose seeds injection:0.50 onto missing strengths" 0 0 "injection:0.50" "$(python3 -c "import json; print(json.load(open('$PPATH2'))['endpoints'][0]['strengths'])")"

echo "== calibrate: apply =="
# copy-on-write to CLAUDE_PLUGIN_DATA, base = shipped CALR
CALDATA="$(mktemp -d)"
CLAUDE_PLUGIN_DATA="$CALDATA" ENSEMBLE_ROSTER= bash -c "ENSEMBLE_ROSTER= CLAUDE_PLUGIN_DATA='$CALDATA' '$ROOT/scripts/ens-calibrate.sh' apply --proposed '$PPATH'" >/dev/null 2>&1; rc=$?
# NOTE: with ENSEMBLE_ROSTER unset and CLAUDE_PLUGIN_DATA set, target=CLAUDE_PLUGIN_DATA/roster.json
check "apply copy-on-write exits 0" 0 "$rc"
check "apply wrote plugin-data roster" 0 "$([ -f "$CALDATA/roster.json" ] && echo 0 || echo 1)"
check "apply seeded .bak" 0 "$([ -f "$CALDATA/roster.json.bak" ] && echo 0 || echo 1)"
bash "$ROOT/scripts/ens-setup.sh" validate "$CALDATA/roster.json" >/dev/null 2>&1
check "applied roster validates" 0 "$?"

echo "== calibrate: apply refusals =="
BADP="$(mktemp)"; python3 -c "import json; r=json.load(open('$CALR')); r['endpoints'][0]['effort']='bogus'; json.dump(r,open('$BADP','w'))"
BADDATA="$(mktemp -d)"
CLAUDE_PLUGIN_DATA="$BADDATA" bash -c "ENSEMBLE_ROSTER= CLAUDE_PLUGIN_DATA='$BADDATA' '$ROOT/scripts/ens-calibrate.sh' apply --proposed '$BADP'" >/dev/null 2>&1; rc=$?
check "apply refuses invalid roster -> exit 5" 5 "$rc"
check "apply refusal wrote nothing" 0 "$([ ! -f "$BADDATA/roster.json" ] && echo 0 || echo 1)"

# modified endpoint emptied -> refuse 5; base = CALR (strengths non-empty)
EMPTYP="$(mktemp)"; python3 -c "import json; r=json.load(open('$CALR')); r['endpoints'][0]['strengths']=[]; r['endpoints'][0]['strengths_basis']='calibrated x'; json.dump(r,open('$EMPTYP','w'))"
EDATA="$(mktemp -d)"
ENSEMBLE_ROSTER="$CALR" bash -c "CLAUDE_PLUGIN_DATA='$EDATA' ENSEMBLE_ROSTER='$CALR' '$ROOT/scripts/ens-calibrate.sh' apply --proposed '$EMPTYP'" >/dev/null 2>&1; rc=$?
check "apply guard: modified endpoint emptied -> exit 5" 5 "$rc"

# pre-existing UNRELATED empty-strengths endpoint must NOT block apply
BASE3="$(mktemp)"
cat > "$BASE3" <<'JSON'
{"min_quorum":1,"reviewers_default":["t@codex"],"endpoints":[
 {"id":"t@codex","adapter":"codex","model":"gpt-5.5","family":"openai","effort":"medium","read_only_mode":"sandbox-read-only","role":"both","structured_output":"json","strengths":["repo-reasoning"],"latency_tier":"slow","enabled":true},
 {"id":"u@grok","adapter":"grok","model":"grok-build","family":"xai","effort":"medium","read_only_mode":"permission-mode-plan","role":"both","structured_output":"sentinel","strengths":[],"latency_tier":"fast","enabled":true}
]}
JSON
PROP3="$(mktemp)"; python3 -c "import json; r=json.load(open('$BASE3')); r['endpoints'][0]['strengths']=['injection:0.50','repo-reasoning']; r['endpoints'][0]['strengths_basis']='calibrated 2026-06-28'; json.dump(r,open('$PROP3','w'))"
D3="$(mktemp -d)"
ENSEMBLE_ROSTER="$BASE3" bash -c "CLAUDE_PLUGIN_DATA='$D3' ENSEMBLE_ROSTER='$BASE3' '$ROOT/scripts/ens-calibrate.sh' apply --proposed '$PROP3'" >/dev/null 2>&1; rc=$?
check "apply NOT blocked by a pre-existing unrelated empty-strengths endpoint" 0 "$rc"

echo "== calibrate: surface contract =="
check "calibrate command exists" 0 "$([ -f "$ROOT/commands/calibrate.md" ] && echo 0 || echo 1)"
check "calibrate skill exists" 0 "$([ -f "$ROOT/skills/ensemble-calibrate/SKILL.md" ] && echo 0 || echo 1)"

rm -rf "$CALSTUB" "$CALR" "$CALR2" "$CALC" "$CALC2" "$CALPRES" "$PERR" "$BADP" "$BADDATA" "$EMPTYP" "$EDATA" "$BASE3" "$PROP3" "$CALDATA" "$D3" 2>/dev/null || true
