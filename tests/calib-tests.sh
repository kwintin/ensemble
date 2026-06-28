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
  hit)           emit CHANGES "found the planted bug XYZZY here"; exit 0;;
  miss)          emit CHANGES "this code looks fine to me"; exit 0;;
  approve)       emit APPROVED "looks clean"; exit 0;;
  approve_xyzzy) emit APPROVED "the bug XYZZY is here but I approve anyway"; exit 0;;
  error_raw)     emit ERROR "the bug XYZZY is present"; exit 3;;
  empty)         exit 3;;
  quota)         exit 10;;
  auth)          exit 11;;
  timeout)       exit 12;;
  *)             emit CHANGES "no directive"; exit 0;;
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
# real trap-cleanup assertion: route the engine's mktemp into a controlled TMPDIR and
# confirm nothing is left behind after the run (the EXIT trap removed RUN_TEMP).
LEAKT="$(mktemp -d)"
TMPDIR="$LEAKT" ENS_MODEL_CLI="$CALSTUB" ENSEMBLE_ROSTER="$CALR" bash "$ROOT/scripts/ens-calibrate.sh" run --corpus "$CALC" >/dev/null 2>&1
check "run cleans up its temp dirs (EXIT trap)" 0 0 "0" "$(find "$LEAKT" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"
rm -rf "$LEAKT"

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

echo "== calibrate: list verb =="
LRES="$(bash "$ROOT/scripts/ens-calibrate.sh" list --corpus "$CALC" 2>/dev/null)"; rc=$?
check "list exits 0" 0 "$rc"
check "list reports total fixtures" 0 0 '"total": 4' "$LRES"
check "list reports a category" 0 0 "injection" "$LRES"
EMPTYC="$(mktemp -d)"
bash "$ROOT/scripts/ens-calibrate.sh" list --corpus "$EMPTYC" >/dev/null 2>&1
check "list empty corpus -> exit 3" 3 "$?"; rmdir "$EMPTYC"
bash "$ROOT/scripts/ens-calibrate.sh" list --corpus /no-such-dir-xyz >/dev/null 2>&1
check "list missing corpus -> exit 1" 1 "$?"

echo "== calibrate: run grading edge cases =="
CALCX="$(mktemp -d)"
xmk(){ mkdir -p "$CALCX/$1/$2"; printf 'x = 1  #STUB %s\n' "$3" > "$CALCX/$1/$2/input.py"
  printf '%s' "$4" > "$CALCX/$1/$2/expect.json"; }
xmk injection anyhit hit       '{"category":"injection","verdict":"CHANGES","must_match":["NOPE-NOT-PRESENT","XYZZY"],"must_match_mode":"any"}'
xmk bugs       cryWolf approve_xyzzy '{"category":"bugs","verdict":"CHANGES","must_match":["XYZZY"],"must_match_mode":"all"}'
xmk perf       q1 quota       '{"category":"perf","verdict":"CHANGES","must_match":["X"],"must_match_mode":"all"}'
xmk type-drift a1 auth        '{"category":"type-drift","verdict":"CHANGES","must_match":["X"],"must_match_mode":"all"}'
RESX="$(ENS_MODEL_CLI="$CALSTUB" ENSEMBLE_ROSTER="$CALR" bash "$ROOT/scripts/ens-calibrate.sh" run --corpus "$CALCX" 2>/dev/null)"
xval(){ printf '%s' "$RESX" | python3 -c "import json,sys; d=json.load(sys.stdin); print($1)"; }
check "must_match_mode any: one-of-two matches -> hit" 0 0 "1.0" "$(xval 'd["ran"][0]["categories"]["injection"]["score"]')"
check "CHANGES fixture + model verdict APPROVED -> miss" 0 0 "0.0" "$(xval 'd["ran"][0]["categories"]["bugs"]["score"]')"
check "skip reason quota (exit 10)" 0 0 "quota" "$(xval '[f["reason"] for f in d["ran"][0]["fixtures"] if f["category"]=="perf"][0]')"
check "skip reason auth (exit 11)" 0 0 "auth" "$(xval '[f["reason"] for f in d["ran"][0]["fixtures"] if f["category"]=="type-drift"][0]')"

echo "== calibrate: propose sort / replace / skipped-endpoint =="
# base with a prior scored tag + a bare tag; measure a lower-scored category -> sort order
SROST="$(mktemp)"; python3 -c "import json; r=json.load(open('$CALR')); r['endpoints'][0]['strengths']=['type-drift:0.67','repo-reasoning']; json.dump(r,open('$SROST','w'))"
SR="$(mktemp)"; cat > "$SR" <<'JSON'
{"corpus_total":1,"scope":{"endpoint":null,"category":null},"date":"2026-06-28","ran":[
 {"id":"t@codex","family":"openai","categories":{"perf":{"score":0.2,"n":5,"hits":1,"misses":4,"skipped":0}},"fixtures":[]}]}
JSON
SP="$(ENSEMBLE_ROSTER="$SROST" bash "$ROOT/scripts/ens-calibrate.sh" propose --result "$SR" 2>/dev/null)"
SPATH="$(printf '%s' "$SP" | python3 -c 'import json,sys; print(json.load(sys.stdin)["proposed_roster"])')"
check "scored block sorts higher score first (prior 0.67 before fresh 0.20)" 0 0 "['type-drift:0.67', 'perf:0.20', 'repo-reasoning']" "$(python3 -c "import json; print(json.load(open('$SPATH'))['endpoints'][0]['strengths'])")"

# replace an existing scored entry for the same category (no duplicate)
RROST="$(mktemp)"; python3 -c "import json; r=json.load(open('$CALR')); r['endpoints'][0]['strengths']=['injection:0.20','repo-reasoning']; json.dump(r,open('$RROST','w'))"
RR="$(mktemp)"; cat > "$RR" <<'JSON'
{"corpus_total":1,"scope":{"endpoint":null,"category":null},"date":"2026-06-28","ran":[
 {"id":"t@codex","family":"openai","categories":{"injection":{"score":0.8,"n":5,"hits":4,"misses":1,"skipped":0}},"fixtures":[]}]}
JSON
RP="$(ENSEMBLE_ROSTER="$RROST" bash "$ROOT/scripts/ens-calibrate.sh" propose --result "$RR" 2>/dev/null)"
RPATH="$(printf '%s' "$RP" | python3 -c 'import json,sys; print(json.load(sys.stdin)["proposed_roster"])')"
rstr="$(python3 -c "import json; print(json.load(open('$RPATH'))['endpoints'][0]['strengths'])")"
check "propose replaces same-category scored entry (new score present)" 0 0 "injection:0.80" "$rstr"
check "propose replaces same-category scored entry (old score gone)" 0 "$(printf '%s' "$rstr" | grep -q 'injection:0.20' && echo 1 || echo 0)"

# fully-skipped endpoint that IS in the roster -> left untouched, not in changes
KR="$(mktemp)"; cat > "$KR" <<'JSON'
{"corpus_total":1,"scope":{"endpoint":null,"category":null},"date":"2026-06-28","ran":[
 {"id":"t@codex","family":"openai","categories":{"perf":{"score":null,"n":0,"hits":0,"misses":0,"skipped":3}},"fixtures":[]}]}
JSON
KP="$(ENSEMBLE_ROSTER="$CALR" bash "$ROOT/scripts/ens-calibrate.sh" propose --result "$KR" 2>/dev/null)"
check "fully-skipped roster endpoint -> no changes" 0 0 "[]" "$(printf '%s' "$KP" | python3 -c 'import json,sys; print([c["id"] for c in json.load(sys.stdin)["changes"]])')"
KPATH="$(printf '%s' "$KP" | python3 -c 'import json,sys; print(json.load(sys.stdin)["proposed_roster"])')"
check "fully-skipped endpoint strengths preserved" 0 0 "['repo-reasoning', 'type-drift']" "$(python3 -c "import json; print(json.load(open('$KPATH'))['endpoints'][0]['strengths'])")"

# malformed result -> exit 2
printf 'this is not json' | ENSEMBLE_ROSTER="$CALR" bash "$ROOT/scripts/ens-calibrate.sh" propose >/dev/null 2>&1
check "propose malformed result -> exit 2" 2 "$?"

echo "== calibrate: apply via ENSEMBLE_ROSTER target =="
EROST="$(mktemp)"; cp "$CALR" "$EROST"
EAP="$(mktemp)"; python3 -c "import json; r=json.load(open('$EROST')); r['endpoints'][0]['strengths']=['injection:0.50','repo-reasoning']; r['endpoints'][0]['strengths_basis']='calibrated 2026-06-28'; json.dump(r,open('$EAP','w'))"
written="$(ENSEMBLE_ROSTER="$EROST" bash -c "ENSEMBLE_ROSTER='$EROST' CLAUDE_PLUGIN_DATA= '$ROOT/scripts/ens-calibrate.sh' apply --proposed '$EAP'" 2>/dev/null)"; rc=$?
check "apply via ENSEMBLE_ROSTER exits 0" 0 "$rc"
check "apply wrote the ENSEMBLE_ROSTER path" 0 0 "$EROST" "$written"
check "apply via ENSEMBLE_ROSTER persisted the calibration" 0 0 "injection:0.50" "$(python3 -c "import json; print(json.load(open('$EROST'))['endpoints'][0]['strengths'])")"

rm -rf "$CALSTUB" "$CALR" "$CALR2" "$CALC" "$CALC2" "$CALCX" "$CALPRES" "$PERR" "$BADP" "$BADDATA" "$EMPTYP" "$EDATA" "$BASE3" "$PROP3" "$CALDATA" "$D3" "$SROST" "$SR" "$RROST" "$RR" "$KR" "$EROST" "$EAP" 2>/dev/null || true
