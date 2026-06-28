#!/usr/bin/env bash
set -uo pipefail
ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
SCRIPTS="$ROOT/scripts"
ROSTER="${ENSEMBLE_ROSTER:-$ROOT/roster.json}"
source "$SCRIPTS/lib/roster.sh"

die() { echo "ens-review: $*" >&2; exit 1; }

PROMPT_FILE=""; SUBSET=""; STDIN_TMP=""
while [ $# -gt 0 ]; do
  case "$1" in
    --reviewers) SUBSET="$2"; shift 2 ;;
    --prompt-file) PROMPT_FILE="$2"; shift 2 ;;
    -) PROMPT_FILE="$(mktemp)"; cat > "$PROMPT_FILE"; STDIN_TMP="$PROMPT_FILE"; shift ;;
    *) die "unknown arg '$1'" ;;
  esac
done
[ -n "$PROMPT_FILE" ] && [ -f "$PROMPT_FILE" ] || die "need --prompt-file or '-'"

# select reviewers
if [ -n "$SUBSET" ]; then
  IFS=',' read -r -a REVIEWERS <<< "$SUBSET"
else
  mapfile -t REVIEWERS < <(ens_reviewers "$ROSTER")
fi
[ "${#REVIEWERS[@]}" -gt 0 ] || die "no reviewers selected"

# test-only: parse ENS_TEST_MODES "id=mode,id=mode" -> per-endpoint STUB_MODE
test_mode_for() { # ENDPOINT -> mode or empty
  local ep="$1" pair
  local -a _pairs
  [ -n "${ENS_TEST_MODES:-}" ] || return 0
  IFS=',' read -r -a _pairs <<< "$ENS_TEST_MODES"
  for pair in "${_pairs[@]}"; do
    case "$pair" in "$ep="*) echo "${pair#*=}"; return 0 ;; esac
  done
}

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"; [ -n "$STDIN_TMP" ] && rm -f "$STDIN_TMP"' EXIT

RO_BEFORE="$(git status --porcelain 2>/dev/null || true)"
RO_UNTRACKED_BEFORE=()
while IFS= read -r -d '' f; do RO_UNTRACKED_BEFORE+=("$f"); done < <(git ls-files --others --exclude-standard -z 2>/dev/null)

# dispatch each reviewer in the background
# NOTE: endpoint ids are used as temp-file names; the roster schema is name@adapter (no '/').
for ep in "${REVIEWERS[@]}"; do
  mode="$(test_mode_for "$ep")"
  ( STUB_MODE="${mode:-ok}" "$SCRIPTS/model-cli.sh" review --endpoint "$ep" --prompt-file "$PROMPT_FILE" \
      >"$WORK/$ep.out" 2>"$WORK/$ep.err"; echo $? >"$WORK/$ep.rc" ) &
done
wait

RO_AFTER="$(git status --porcelain 2>/dev/null || true)"
RO_VIOLATION=0; RO_FILES=""
if [ "$RO_BEFORE" != "$RO_AFTER" ]; then
  RO_VIOLATION=1
  # changed/new porcelain lines present after but not before; strip the 3-char status prefix
  RO_FILES="$(comm -13 <(printf '%s\n' "$RO_BEFORE" | sort) <(printf '%s\n' "$RO_AFTER" | sort) | sed 's/^...//' | tr '\n' ',')"
  git checkout -- . 2>/dev/null || true   # revert tracked modifications
  # remove ONLY newly-appeared untracked files (NUL-safe; preserves pre-existing untracked files)
  while IFS= read -r -d '' f; do
    _skip=0
    for _b in ${RO_UNTRACKED_BEFORE[@]+"${RO_UNTRACKED_BEFORE[@]}"}; do
      [ "$_b" = "$f" ] && { _skip=1; break; }
    done
    [ "$_skip" -eq 0 ] && rm -f -- "$f"
  done < <(git ls-files --others --exclude-standard -z 2>/dev/null)
fi

python3 - "$WORK" "$ROSTER" "$RO_VIOLATION" "$RO_FILES" "${REVIEWERS[@]}" <<'PY'
import json,os,sys
from collections import defaultdict
work,roster=sys.argv[1],sys.argv[2]; ro_v=sys.argv[3]; ro_files=sys.argv[4]; eps=sys.argv[5:]
rd=json.load(open(roster, encoding="utf-8"))
fam={e["id"]:e.get("family") for e in (rd.get("endpoints") or []) if isinstance(e,dict) and e.get("id")}
REASON={2:"failed",3:"empty",10:"quota",11:"auth",12:"timeout",13:"missing"}
reviewers=[]
for ep in eps:
    p=os.path.join(work,ep)
    rc=int(open(p+".rc").read().strip()) if os.path.exists(p+".rc") else 1
    rec={"endpoint":ep,"family":fam.get(ep),"status":"ok","reason":None,"verdict":None,"findings":[]}
    if rc==0:
        try:
            v=json.load(open(p+".out", encoding="utf-8"))
            rec["verdict"]=v.get("verdict"); rec["findings"]=v.get("findings") or []
        except Exception:
            rec["status"]="degraded"; rec["reason"]="unparseable"
    else:
        rec["status"]="degraded"; rec["reason"]=REASON.get(rc,"failed")
    reviewers.append(rec)

min_q = rd.get("min_quorum", 2)
ok = [r for r in reviewers if r["status"]=="ok"]
fams_ok=[]
seen=set()
for r in ok:
    f=r["family"]
    if f and f not in seen: seen.add(f); fams_ok.append(f)
# collisions: families with >1 ok reviewer
by=defaultdict(list)
for r in ok:
    if r["family"]: by[r["family"]].append(r["endpoint"])
collisions=[{"family":k,"endpoints":v} for k,v in by.items() if len(v)>1]
quorum_met = len(fams_ok) >= min_q
res={"reviewers":reviewers,"families_ok":fams_ok,"family_collisions":collisions,
     "quorum_required":min_q,"quorum_met":quorum_met,
     "read_only_violation": ro_v=="1",
     "mutated_files": [f for f in ro_files.split(",") if f]}
print(json.dumps(res, indent=2))
if ro_v=="1": sys.exit(5)
sys.exit(0 if quorum_met else 4)
PY
exit $?
