#!/usr/bin/env bash
# ens-calibrate.sh — measure per-category review hit-rate over a fixture corpus and
# propose grounded `strengths` (scored cat:score tags) for the roster.
# Verbs: list | run | propose | apply   (design: docs/specs/2026-06-28-ensemble-calibrate-design.md)
#
# Token spend happens ONLY in `run`. list/propose/apply spend nothing. The `run`
# result JSON goes to STDOUT; human-readable progress goes to STDERR.
#
# Exit codes: 0 ok · 1 usage / unresolved-or-unwritable target / bad --corpus ·
#   2 failed (bad input) · 3 empty corpus · 4 nothing measured (all skipped) ·
#   5 apply refused (invalid/degraded proposed roster).
set -uo pipefail
ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
SCRIPTS="$ROOT/scripts"
source "$SCRIPTS/lib/roster-path.sh"   # resolves ROSTER (read base): ENSEMBLE_ROSTER | CLAUDE_PLUGIN_DATA | shipped
source "$SCRIPTS/lib/roster.sh"

die()  { echo "ens-calibrate: $*" >&2; exit 1; }
log()  { echo "ens-calibrate: $*" >&2; }

CORPUS_DEFAULT="$ROOT/fixtures"
# model-cli is overridable so tests can inject a stub (real path otherwise).
MODEL_CLI="${ENS_MODEL_CLI:-$SCRIPTS/model-cli.sh}"

# Category-agnostic review prompt (names every corpus concern-domain so no category is
# under-elicited; identical for every fixture so none gets a leading hint).
PROMPT_HEADER='Review this file for any defects — correctness, security, performance, type-safety, concurrency, and financial/payment-logic bugs. List each as file:line — issue.'

# ─────────────────────────────────────────────────────────────────────────────
# list [--corpus DIR]
# ─────────────────────────────────────────────────────────────────────────────
cmd_list() {
  local corpus="$CORPUS_DEFAULT"
  while [ $# -gt 0 ]; do case "$1" in
    --corpus) corpus="$2"; shift 2 ;; *) die "list: unknown arg '$1'" ;;
  esac; done
  [ -d "$corpus" ] || die "corpus dir not found: $corpus"   # exit 1
  python3 - "$corpus" <<'PY'
import json, os, sys
corpus = sys.argv[1]
cats, fixtures = {}, []
for cat in sorted(os.listdir(corpus)):
    cp = os.path.join(corpus, cat)
    if not os.path.isdir(cp): continue
    for name in sorted(os.listdir(cp)):
        fp = os.path.join(cp, name)
        if not os.path.isdir(fp): continue
        if not os.path.exists(os.path.join(fp, "expect.json")): continue
        cats[cat] = cats.get(cat, 0) + 1
        fixtures.append({"category": cat, "name": name, "path": fp})
total = len(fixtures)
print(json.dumps({"categories": cats, "total": total, "fixtures": fixtures}, indent=2))
sys.exit(3 if total == 0 else 0)
PY
}

# ─────────────────────────────────────────────────────────────────────────────
# run [--endpoint ID] [--category CAT] [--corpus DIR]
# ─────────────────────────────────────────────────────────────────────────────
cmd_run() {
  local corpus="$CORPUS_DEFAULT" only_ep="" only_cat=""
  while [ $# -gt 0 ]; do case "$1" in
    --endpoint) only_ep="$2"; shift 2 ;;
    --category) only_cat="$2"; shift 2 ;;
    --corpus)   corpus="$2";   shift 2 ;;
    *) die "run: unknown arg '$1'" ;;
  esac; done
  [ -d "$corpus" ] || die "corpus dir not found: $corpus"   # exit 1
  [ -r "$ROSTER" ] || die "roster '$ROSTER' missing or unreadable"

  # target endpoints: enabled reviewers (role reviewer|both); --endpoint narrows to one
  local eps=(); while IFS= read -r e; do [ -n "$e" ] && eps+=("$e"); done < <(ens_reviewers "$ROSTER")
  if [ -n "$only_ep" ]; then
    local f=0; for e in "${eps[@]:-}"; do [ "$e" = "$only_ep" ] && f=1; done
    [ "$f" -eq 1 ] || die "run: --endpoint '$only_ep' is not an enabled reviewer"
    eps=("$only_ep")
  fi
  [ "${#eps[@]}" -gt 0 ] || die "run: no enabled reviewer endpoints"

  # honor $TMPDIR explicitly via a template: bare `mktemp -d` ignores $TMPDIR on macOS
  # (it uses _CS_DARWIN_USER_TEMP_DIR), which would also make the trap-cleanup test vacuous.
  # RUN_TEMP is INTENTIONALLY NOT `local`: the EXIT trap fires after this function returns,
  # when a local would be out of scope — so a local RUN_TEMP would leak (the trap's
  # `[ -n "${RUN_TEMP:-}" ]` guard would see an empty value and skip the rm).
  RUN_TEMP="$(mktemp -d "${TMPDIR:-/tmp}/ens-calib.XXXXXX")" || die "mktemp failed"
  trap '[ -n "${RUN_TEMP:-}" ] && rm -rf "$RUN_TEMP"' EXIT
  # on signal: clean up AND exit (130) so the loop doesn't continue into deleted paths
  trap '[ -n "${RUN_TEMP:-}" ] && rm -rf "$RUN_TEMP"; exit 130' INT TERM

  # enumerate fixtures (sorted, optionally filtered) as TSV: category<TAB>name<TAB>dir<TAB>input
  local FIXTSV="$RUN_TEMP/fixtures.tsv"
  python3 - "$corpus" "$only_cat" > "$FIXTSV" <<'PY'
import os, sys
corpus, only = sys.argv[1], sys.argv[2]
for cat in sorted(os.listdir(corpus)):
    if only and cat != only: continue
    cp = os.path.join(corpus, cat)
    if not os.path.isdir(cp): continue
    for name in sorted(os.listdir(cp)):
        fp = os.path.join(cp, name)
        if not os.path.isdir(fp): continue
        ins = [x for x in sorted(os.listdir(fp)) if x.startswith("input.")]
        if len(ins) != 1 or not os.path.exists(os.path.join(fp, "expect.json")): continue
        print("%s\t%s\t%s\t%s" % (cat, name, fp, ins[0]))
PY
  local nfix; nfix="$(wc -l < "$FIXTSV" | tr -d ' ')"
  [ "${nfix:-0}" -gt 0 ] || { [ -n "$only_cat" ] && die "run: no fixtures in category '$only_cat'"; log "empty corpus: no fixtures under $corpus"; exit 3; }

  local JOBS="$RUN_TEMP/jobs.tsv"; : > "$JOBS"
  local total_runs=$(( ${#eps[@]} * nfix )) done=0 i=0
  log "running $total_runs review(s): ${#eps[@]} endpoint(s) × $nfix fixture(s)"

  # endpoints outer, fixtures inner — sequential, deterministic
  for ep in "${eps[@]}"; do
    while IFS=$'\t' read -r cat name fdir finput; do
      [ -n "$cat" ] || continue
      i=$((i+1))
      local sub="$RUN_TEMP/$i"; mkdir -p "$sub"
      cp "$fdir/$finput" "$sub/$finput"
      # best-effort isolated git repo (gives codex --sandbox a clean workspace; hardened
      # so a global commit.gpgsign / hooks can't hang or fail it). Non-fatal if git absent.
      git -C "$sub" -c init.defaultBranch=main init -q >/dev/null 2>&1 \
        && git -C "$sub" -c commit.gpgsign=false -c core.hooksPath=/dev/null \
               -c user.email=calib@ensemble -c user.name=calib add -A >/dev/null 2>&1 \
        && git -C "$sub" -c commit.gpgsign=false -c core.hooksPath=/dev/null \
               -c user.email=calib@ensemble -c user.name=calib commit -q -m fixture >/dev/null 2>&1 || true

      local prompt out err rc
      prompt="$(printf '%s\n\n--- %s ---\n%s' "$PROMPT_HEADER" "$finput" "$(cat "$fdir/$finput")")"
      out="$RUN_TEMP/$i.out"; err="$RUN_TEMP/$i.err"
      ( cd "$sub" && printf '%s' "$prompt" | "$MODEL_CLI" review --endpoint "$ep" - ) >"$out" 2>"$err"
      rc=$?
      done=$((done+1))
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$ep" "$cat" "$name" "$rc" "$out" "$fdir/expect.json" >> "$JOBS"
      log "  [$done/$total_runs] $ep  $cat/$name  (rc=$rc)"
    done < "$FIXTSV"
  done

  # grade + aggregate
  ENS_SCOPE_EP="$only_ep" ENS_SCOPE_CAT="$only_cat" ENS_CORPUS_TOTAL="$nfix" \
  ENS_CALIB_DATE="$(date -u +%Y-%m-%d)" \
  python3 - "$JOBS" "$ROSTER" <<'PY'
import json, os, re, sys
jobs_path, roster_path = sys.argv[1], sys.argv[2]
scope_ep  = os.environ.get("ENS_SCOPE_EP","") or None
scope_cat = os.environ.get("ENS_SCOPE_CAT","") or None
corpus_total = int(os.environ.get("ENS_CORPUS_TOTAL","0"))

try:
    roster = json.load(open(roster_path, encoding="utf-8"))
except Exception:
    roster = {}
fam = {e.get("id"): e.get("family") for e in (roster.get("endpoints") or [])
       if isinstance(e, dict)}

def gradable_and_verdict(out_path):
    """Return (text, verdict) if a usable envelope with non-empty raw is present, else (None, None)."""
    try:
        env = json.load(open(out_path, encoding="utf-8"))
    except Exception:
        return None, None
    if not isinstance(env, dict): return None, None
    raw = env.get("raw")
    raw = raw if isinstance(raw, str) else ""
    parts = [raw]
    for f in (env.get("findings") or []):
        if isinstance(f, dict):
            t = f.get("issue") or f.get("message") or f.get("title")
            if t: parts.append(str(t))
    text = "\n".join(parts)
    if not text.strip():
        return None, None
    return text, str(env.get("verdict", "ERROR")).upper()

def reason_for(rc, out_path):
    r = {10:"quota",11:"auth",12:"timeout",13:"missing"}.get(rc)
    if r: return r
    if rc not in (0, 3): return "failed"
    # exit 0/3 with no usable raw: distinguish nothing-returned from garbled output
    try:
        content = open(out_path, encoding="utf-8").read()
    except Exception:
        return "empty"
    if not content.strip(): return "empty"
    try:
        json.loads(content); return "empty"      # valid envelope but raw was empty
    except Exception:
        return "unparseable"                      # the CLI returned non-envelope text

# endpoint -> ordered dict of category -> {hits,misses,skipped}; endpoint -> fixtures[]
order_eps = []
agg = {}     # ep -> {cat -> {"hits":,"misses":,"skipped":}}
fxs = {}     # ep -> [ {category,name,outcome,reason} ]

for line in open(jobs_path, encoding="utf-8"):
    line = line.rstrip("\n")
    if not line: continue
    ep, cat, name, rc, out_path, expect_path = line.split("\t")
    rc = int(rc)
    if ep not in agg:
        order_eps.append(ep); agg[ep] = {}; fxs[ep] = []
    agg[ep].setdefault(cat, {"hits":0,"misses":0,"skipped":0})
    try:
        expect = json.load(open(expect_path, encoding="utf-8"))
    except Exception:
        expect = {"verdict":"CHANGES","must_match":[],"must_match_mode":"all"}
    text, verdict = gradable_and_verdict(out_path)
    if text is None:
        agg[ep][cat]["skipped"] += 1
        fxs[ep].append({"category":cat,"name":name,"outcome":"skip","reason":reason_for(rc, out_path)})
        continue
    pats = expect.get("must_match") or []
    mode = expect.get("must_match_mode","all")
    def hit_pat(p):
        try: return re.search(p, text, re.IGNORECASE) is not None
        except re.error: return False
    if pats:
        matched = all(hit_pat(p) for p in pats) if mode == "all" else any(hit_pat(p) for p in pats)
    else:
        matched = True  # APPROVED control with empty must_match
    exp_verdict = str(expect.get("verdict","CHANGES")).upper()
    if exp_verdict == "APPROVED":
        hit = (verdict == "APPROVED") and matched
    else:  # CHANGES: bug must be named; explicit APPROVE of buggy code is not a hit
        hit = matched and verdict != "APPROVED"
    if hit:
        agg[ep][cat]["hits"] += 1; outcome = "hit"
    else:
        agg[ep][cat]["misses"] += 1; outcome = "miss"
    fxs[ep].append({"category":cat,"name":name,"outcome":outcome,"reason":None})

ran = []
total_graded = 0
for ep in order_eps:
    cats = {}
    for cat, c in agg[ep].items():
        n = c["hits"] + c["misses"]
        total_graded += n
        cats[cat] = {
            "score": round(c["hits"]/n, 2) if n > 0 else None,
            "n": n, "hits": c["hits"], "misses": c["misses"], "skipped": c["skipped"],
        }
    ran.append({"id": ep, "family": fam.get(ep), "categories": cats, "fixtures": fxs[ep]})

result = {
    "corpus_total": corpus_total,
    "scope": {"endpoint": scope_ep, "category": scope_cat},
    "date": os.environ.get("ENS_CALIB_DATE",""),  # filled by bash for testability
    "ran": ran,
}
print(json.dumps(result, indent=2))
sys.exit(4 if total_graded == 0 else 0)
PY
}

# ─────────────────────────────────────────────────────────────────────────────
# propose --result FILE [--corpus DIR]
# ─────────────────────────────────────────────────────────────────────────────
cmd_propose() {
  local result=""
  while [ $# -gt 0 ]; do case "$1" in
    --result) result="$2"; shift 2 ;;
    --corpus) shift 2 ;;   # accepted for symmetry; unused
    *) die "propose: unknown arg '$1'" ;;
  esac; done
  local rsrc rtmp=""
  if [ -n "$result" ]; then [ -f "$result" ] || die "propose: --result file not found: $result"; rsrc="$result"
  else rsrc="$(mktemp)"; rtmp="$rsrc"; cat > "$rsrc"; fi   # stdin
  [ -r "$ROSTER" ] || die "roster '$ROSTER' missing or unreadable"

  python3 - "$rsrc" "$ROSTER" <<'PY'
import json, os, re, sys, tempfile
result_path, roster_path = sys.argv[1], sys.argv[2]
try:
    result = json.load(open(result_path, encoding="utf-8"))
except Exception as e:
    sys.stderr.write("propose: malformed result JSON: %s\n" % e); sys.exit(2)
if not isinstance(result, dict) or "ran" not in result or "scope" not in result or "date" not in result:
    sys.stderr.write("propose: result missing ran/scope/date\n"); sys.exit(2)
try:
    roster = json.load(open(roster_path, encoding="utf-8"))
except Exception as e:
    sys.stderr.write("propose: cannot read roster: %s\n" % e); sys.exit(2)

by_id = {e.get("id"): e for e in (roster.get("endpoints") or []) if isinstance(e, dict)}
date = result.get("date") or ""
SCORED = re.compile(r'^[a-z0-9][a-z0-9-]*:[0-9.]+$')

def score_key(entry):
    try: return float(entry.split(":",1)[1])
    except (ValueError, IndexError): return 0.0   # malformed score sorts lowest, never crashes

changes = []
for r in result.get("ran") or []:
    eid = r.get("id"); cats = r.get("categories") or {}
    measured = {c: v["score"] for c, v in cats.items()
                if isinstance(v, dict) and v.get("n",0) > 0 and v.get("score") is not None}
    total_graded = sum(v.get("n",0) for v in cats.values() if isinstance(v, dict))
    if total_graded == 0:
        continue                                  # fully-skipped endpoint: leave untouched
    ep = by_id.get(eid)
    if ep is None:
        sys.stderr.write("propose: warning: endpoint '%s' in result but absent from roster — skipped\n" % eid)
        continue
    old = ep.get("strengths")
    old = list(old) if isinstance(old, list) else []   # missing/null -> []
    # remove any existing entry for a measured category (bare or scored)
    def is_measured_entry(s):
        return any(re.match(r'^' + re.escape(c) + r'(:.*)?$', s) for c in measured)
    kept = [s for s in old if not is_measured_entry(s)]
    new_scored = ["%s:%.2f" % (c, measured[c]) for c in measured]
    combined = new_scored + kept
    # sort: scored block (by score desc, then name asc) first; bare block in original order
    scored = [s for s in combined if SCORED.match(s)]
    bare   = [s for s in combined if not SCORED.match(s)]
    scored.sort(key=lambda s: (-score_key(s), s.split(":",1)[0]))
    new = scored + bare
    measured_str = ", ".join("%s:%.2f" % (c, measured[c]) for c in sorted(measured))
    basis = ("calibrated %s; this run measured: %s (N=%d); "
             "scored tags may derive from earlier runs — re-run to refresh"
             % (date, measured_str, total_graded))
    if new != old or ep.get("strengths_basis") != basis:
        changes.append({"id": eid, "old": old, "new": new})
    ep["strengths"] = new
    ep["strengths_basis"] = basis

# write proposed roster to a temp file (live roster untouched)
fd, proposed = tempfile.mkstemp(prefix="ens-roster-", suffix=".json")
with os.fdopen(fd, "w", encoding="utf-8") as f:
    json.dump(roster, f, indent=2); f.write("\n")

# human-readable diff to stderr
if not changes:
    sys.stderr.write("propose: no strength changes (nothing measured changed).\n")
for ch in changes:
    sys.stderr.write("  %s\n    - %s\n    + %s\n" % (ch["id"], ch["old"], ch["new"]))
print(json.dumps({"proposed_roster": proposed, "changes": changes, "date": date}, indent=2))
PY
  local prc=$?
  [ -n "$rtmp" ] && rm -f "$rtmp"   # clean up the stdin-captured temp (if any)
  return "$prc"
}

# ─────────────────────────────────────────────────────────────────────────────
# apply --proposed FILE
# ─────────────────────────────────────────────────────────────────────────────
cmd_apply() {
  local proposed=""
  while [ $# -gt 0 ]; do case "$1" in
    --proposed) proposed="$2"; shift 2 ;;
    *) die "apply: unknown arg '$1'" ;;
  esac; done
  [ -n "$proposed" ] || die "apply: need --proposed FILE"
  [ -f "$proposed" ] || die "apply: proposed file not found: $proposed"

  # resolve write target — byte-identical to the setup wizard's rule (and to roster-path.sh
  # except the intended first-write copy-on-write). $ROOT is always non-empty.
  local target
  if   [ -n "${ENSEMBLE_ROSTER:-}" ];    then target="$ENSEMBLE_ROSTER"
  elif [ -n "${CLAUDE_PLUGIN_DATA:-}" ]; then target="$CLAUDE_PLUGIN_DATA/roster.json"
  elif [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then target="$CLAUDE_PLUGIN_ROOT/roster.json"
  else target="$ROOT/roster.json"; fi
  local base="$ROSTER"   # the roster propose read (for the modified-endpoint guard + .bak seed)

  # validate the proposed roster (fail closed → exit 5)
  local vout vrc
  vout="$(bash "$SCRIPTS/ens-setup.sh" validate "$proposed" 2>&1)"; vrc=$?
  if [ "$vrc" -ne 0 ]; then echo "$vout" >&2; log "apply refused: proposed roster failed validation"; exit 5; fi

  # non-empty-strengths guard, scoped to endpoints that DIFFER from the base (i.e. that
  # this calibration modified). A pre-existing unrelated empty-strengths endpoint can't block.
  python3 - "$proposed" "$base" <<'PY' || exit 5
import json, sys
prop = json.load(open(sys.argv[1], encoding="utf-8"))
try: base = json.load(open(sys.argv[2], encoding="utf-8"))
except Exception: base = {}
bp = {e.get("id"): e for e in (base.get("endpoints") or []) if isinstance(e, dict)}
bad = []
for e in (prop.get("endpoints") or []):
    if not isinstance(e, dict): continue
    eid = e.get("id"); b = bp.get(eid, {})
    changed = (e.get("strengths") != b.get("strengths")) or (e.get("strengths_basis") != b.get("strengths_basis"))
    if changed and not (e.get("strengths") or []):
        bad.append(eid)
if bad:
    sys.stderr.write("apply: proposal would leave modified endpoint(s) with empty strengths: %s\n" % ", ".join(bad))
    sys.exit(1)
PY

  # write: mkdir -p parent; .bak (seed from base on first copy-on-write); atomic mv
  local tdir; tdir="$(dirname "$target")"
  mkdir -p "$tdir" 2>/dev/null || die "apply: cannot create target dir '$tdir'"
  [ -w "$tdir" ] || die "apply: target dir not writable: $tdir"
  if [ -f "$target" ]; then cp "$target" "$target.bak"
  elif [ -f "$base" ];  then cp "$base" "$target.bak"; fi
  local tmp; tmp="$(mktemp "$tdir/.roster.XXXXXX")" || die "apply: mktemp in target dir failed"
  cat "$proposed" > "$tmp" && mv -f "$tmp" "$target" || { rm -f "$tmp"; die "apply: write failed"; }
  log "applied: wrote $target (backup: $target.bak)"
  echo "$target"
}

verb="${1:-}"; shift || true
case "$verb" in
  list)    cmd_list    "$@" ;;
  run)     cmd_run     "$@" ;;
  propose) cmd_propose "$@" ;;
  apply)   cmd_apply   "$@" ;;
  *) die "verb must be list | run | propose | apply" ;;
esac
