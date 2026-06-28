#!/usr/bin/env bash
set -uo pipefail
ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
SCRIPTS="$ROOT/scripts"
ROSTER="${ENSEMBLE_ROSTER:-$ROOT/roster.json}"
source "$SCRIPTS/lib/roster.sh"

die() { echo "ens-review: $*" >&2; exit 1; }

# ----------------------------------------------------------------------------
# Read-only model: reviewers are agentic CLIs that MIGHT write. Rather than run
# them against the user's working tree and try to detect/revert mutations (a
# large data-loss surface), we run every reviewer cd'd into a DISPOSABLE git
# worktree checked out at HEAD (with the user's uncommitted tracked changes
# replayed in for faithful context). The user's real tree is never touched, so
# any reviewer write lands in the throwaway copy and is discarded wholesale.
# `read_only_violation` becomes a clean informational signal computed in the
# copy. Untracked/ignored files are intentionally NOT copied in, so reviewers
# can neither see nor harm them.
# ----------------------------------------------------------------------------

PROMPT_FILE=""; SUBSET=""; STDIN_TMP=""
WORK=""; WT=""; MAIN_REPO=""; RO_GUARDED=0
PIDS=()

cleanup() {
  # kill any reviewer jobs still running (e.g. on INT/TERM) before tearing down
  for _p in ${PIDS[@]+"${PIDS[@]}"}; do kill "$_p" 2>/dev/null; done
  # remove the disposable worktree (idempotent; safe on a second trap fire)
  if [ -n "$WT" ] && [ -n "$MAIN_REPO" ]; then
    git -C "$MAIN_REPO" worktree remove --force "$WT" >/dev/null 2>&1
    git -C "$MAIN_REPO" worktree prune >/dev/null 2>&1 || true
  fi
  [ -n "$WORK" ] && rm -rf "$WORK"
  [ -n "$STDIN_TMP" ] && rm -f "$STDIN_TMP"
}
trap cleanup EXIT INT TERM

while [ $# -gt 0 ]; do
  case "$1" in
    --reviewers) SUBSET="$2"; shift 2 ;;
    --prompt-file) PROMPT_FILE="$2"; shift 2 ;;
    -) PROMPT_FILE="$(mktemp)"; cat > "$PROMPT_FILE"; STDIN_TMP="$PROMPT_FILE"; shift ;;
    *) die "unknown arg '$1'" ;;
  esac
done
[ -n "$PROMPT_FILE" ] && [ -f "$PROMPT_FILE" ] || die "need --prompt-file or '-'"
# absolutize: reviewers run from the worktree cwd, so a relative path would break
PROMPT_FILE="$(cd "$(dirname "$PROMPT_FILE")" && pwd)/$(basename "$PROMPT_FILE")"

# select reviewers
if [ -n "$SUBSET" ]; then
  IFS=',' read -r -a REVIEWERS <<< "$SUBSET"
else
  mapfile -t REVIEWERS < <(ens_reviewers "$ROSTER")
fi
[ "${#REVIEWERS[@]}" -gt 0 ] || die "no reviewers selected"

# validate + dedup endpoint ids: they become temp-file path components, so reject
# anything that could escape $WORK (path separators, '.'/'..', leading dash).
_seen=","; _deduped=()
for ep in "${REVIEWERS[@]}"; do
  [[ "$ep" =~ ^[A-Za-z0-9._@-]+$ ]] || die "invalid endpoint id '$ep'"
  case "$ep" in -*|.|..|*..*|*/*) die "invalid endpoint id '$ep'" ;; esac
  case "$_seen" in *",$ep,"*) continue ;; esac
  _seen="$_seen$ep,"; _deduped+=("$ep")
done
REVIEWERS=("${_deduped[@]}")

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

WORK="$(mktemp -d)"

# ---- build the disposable review worktree (when inside a git work tree) ----
REVIEW_CWD="$PWD"
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  MAIN_REPO="$(git rev-parse --show-toplevel 2>/dev/null)"
  git worktree prune >/dev/null 2>&1 || true
  WT="$WORK/wt"
  if git worktree add --detach --quiet "$WT" HEAD 2>/dev/null; then
    RO_GUARDED=1
    # replay the user's uncommitted TRACKED changes into the copy for faithful
    # review context (untracked/ignored files are deliberately left out)
    if ! git diff --quiet HEAD 2>/dev/null; then
      git diff --binary HEAD 2>/dev/null | git -C "$WT" apply --index --whitespace=nowarn 2>/dev/null || true
    fi
    # commit the snapshot so the worktree has a CLEAN status baseline; any dirt
    # observed after the reviewers run is therefore a reviewer write
    git -C "$WT" add -A >/dev/null 2>&1 || true
    git -C "$WT" -c user.email=ensemble@local -c user.name=ensemble -c commit.gpgsign=false \
      commit --quiet --no-verify --allow-empty -m ensemble-review-snapshot >/dev/null 2>&1 || true
    REVIEW_CWD="$WT"
  else
    WT=""   # worktree creation failed; fall back to no isolation
  fi
fi

# dispatch each reviewer in the background, cwd = the disposable worktree
for ep in "${REVIEWERS[@]}"; do
  mode="$(test_mode_for "$ep")"
  ( # fail closed: never run a reviewer in the user's real tree if the isolated cwd is unavailable
    cd "$REVIEW_CWD" || { echo "ens-review: cannot enter review dir" >"$WORK/$ep.err"; echo 125 >"$WORK/$ep.rc"; exit; }
    STUB_MODE="${mode:-ok}" "$SCRIPTS/model-cli.sh" review --endpoint "$ep" --prompt-file "$PROMPT_FILE" \
      >"$WORK/$ep.out" 2>"$WORK/$ep.err"; echo $? >"$WORK/$ep.rc" ) &
  PIDS+=("$!")
done
wait
PIDS=()

# did any reviewer write into the isolated copy? (signal only; user tree is safe)
RO_VIOLATION=0; RO_FILES=""
if [ "$RO_GUARDED" = 1 ]; then
  _ro_status="$(git -C "$WT" status --porcelain 2>/dev/null)"
  if [ -n "$_ro_status" ]; then
    RO_VIOLATION=1
    RO_FILES="$(printf '%s\n' "$_ro_status" | sed 's/^...//' | tr '\n' ',')"
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
    if os.sep in ep or ep in (".",".."):  # defense in depth; bash already validated
        continue
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

try:
    min_q=int(rd.get("min_quorum",2))
    if min_q < 1: min_q=2
except Exception:
    min_q=2
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
