#!/usr/bin/env bash
set -uo pipefail
ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
SCRIPTS="$ROOT/scripts"
ROSTER="${ENSEMBLE_ROSTER:-$ROOT/roster.json}"
source "$SCRIPTS/lib/roster.sh"

die() { echo "ens-review: $*" >&2; exit 1; }

PROMPT_FILE=""; SUBSET=""; STDIN_TMP=""
RO_GUARDED=0; RO_STASHED=0
_ro_restore() { [ "$RO_STASHED" = 1 ] && git stash pop --quiet 2>/dev/null || true; }
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

WORK="$(mktemp -d)"; trap '_ro_restore; rm -rf "$WORK"; [ -n "$STDIN_TMP" ] && rm -f "$STDIN_TMP"' EXIT INT TERM

RO_UNTRACKED_BEFORE=()
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  RO_GUARDED=1
  # capture pre-existing untracked files (NUL-safe) so we can distinguish them from reviewer-created ones
  while IFS= read -r -d '' f; do RO_UNTRACKED_BEFORE+=("$f"); done < <(git ls-files --others --exclude-standard -z 2>/dev/null)
  # stash only tracked modifications (no --include-untracked) so reviewer content-overwrites are
  # detectable and untracked files (e.g. the test roster.json) are not inadvertently stashed
  if ! git diff --quiet HEAD 2>/dev/null; then
    git stash push --quiet --message "ensemble-review-snapshot" 2>/dev/null && RO_STASHED=1
  fi
fi

# dispatch each reviewer in the background
# NOTE: endpoint ids are used as temp-file names; the roster schema is name@adapter (no '/').
for ep in "${REVIEWERS[@]}"; do
  mode="$(test_mode_for "$ep")"
  ( STUB_MODE="${mode:-ok}" "$SCRIPTS/model-cli.sh" review --endpoint "$ep" --prompt-file "$PROMPT_FILE" \
      >"$WORK/$ep.out" 2>"$WORK/$ep.err"; echo $? >"$WORK/$ep.rc" ) &
done
wait

RO_VIOLATION=0; RO_FILES=""
if [ "$RO_GUARDED" = 1 ]; then
  _ro_status="$(git status --porcelain 2>/dev/null)"
  if [ -n "$_ro_status" ]; then
    RO_VIOLATION=1
    RO_FILES="$(printf '%s\n' "$_ro_status" | sed 's/^...//' | tr '\n' ',')"
    # revert tracked modifications: safe because stash holds the user's tracked changes
    git checkout -- . 2>/dev/null || true
    # remove only reviewer-created untracked files (NUL-safe; preserves pre-existing untracked)
    while IFS= read -r -d '' f; do
      _skip=0
      for _b in ${RO_UNTRACKED_BEFORE[@]+"${RO_UNTRACKED_BEFORE[@]}"}; do
        [ "$_b" = "$f" ] && { _skip=1; break; }
      done
      [ "$_skip" -eq 0 ] && rm -f -- "$f"
    done < <(git ls-files --others --exclude-standard -z 2>/dev/null)
  fi
fi

python3 - "$WORK" "$ROSTER" "$RO_VIOLATION" "$RO_FILES" "$RO_GUARDED" "${REVIEWERS[@]}" <<'PY'
import json,os,sys
from collections import defaultdict
work,roster=sys.argv[1],sys.argv[2]; ro_v=sys.argv[3]; ro_files=sys.argv[4]; ro_g=sys.argv[5]; eps=sys.argv[6:]
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
     "read_only_guarded": ro_g=="1",
     "mutated_files": [f for f in ro_files.split(",") if f]}
print(json.dumps(res, indent=2))
if ro_v=="1": sys.exit(5)
sys.exit(0 if quorum_met else 4)
PY
exit $?
