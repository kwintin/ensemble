#!/usr/bin/env bash
set -uo pipefail
ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
SCRIPTS="$ROOT/scripts"
source "$SCRIPTS/lib/roster-path.sh"   # resolves ROSTER (ENSEMBLE_ROSTER | CLAUDE_PLUGIN_DATA | shipped)
source "$SCRIPTS/lib/roster.sh"

die() { echo "ens-review: $*" >&2; exit 1; }

# ----------------------------------------------------------------------------
# Read-only model: reviewers are agentic CLIs that MIGHT write. Rather than run
# them against the user's working tree and try to detect/revert mutations (a
# large data-loss surface), we run every reviewer cd'd into a DISPOSABLE git
# worktree checked out at HEAD (with the user's uncommitted tracked changes
# replayed in for faithful context). The user's real tree is never touched, so
# any reviewer write to the working tree lands in the throwaway copy and is
# discarded wholesale. If isolation cannot be established inside a git repo we
# FAIL CLOSED (die) rather than run unguarded.
#
# SCOPE BOUNDARY (documented, not a bug): a *linked* worktree shares the repo's
# .git (object store, refs, config, stash). This isolates working-tree FILES; it
# does NOT sandbox a reviewer that deliberately runs git/shell commands against
# shared refs/stash/config, or writes to absolute paths outside the worktree.
# That requires OS-level sandboxing -- the codex reviewer runs under
# `--sandbox read-only`; the other reviewers are invoked in plan/read-only mode
# and are trusted not to execute mutating commands. Repo hooks are disabled
# during setup (core.hooksPath=/dev/null) so a hostile hook cannot run either.
# ----------------------------------------------------------------------------

PROMPT_FILE=""; SUBSET=""; STDIN_TMP=""
WORK=""; WT=""; MAIN_REPO=""; RO_GUARDED=0; WIP_REPLAYED="none"; RO_BASELINE=""
PIDS=(); _cleaned=0

cleanup() {
  [ "$_cleaned" = 1 ] && return 0
  _cleaned=1
  # kill any reviewer jobs still running (e.g. on INT/TERM) before tearing down
  for _p in ${PIDS[@]+"${PIDS[@]}"}; do kill "$_p" 2>/dev/null; done
  # remove the disposable worktree (idempotent; safe on a second trap fire)
  [ -n "$WT" ] && [ -n "$MAIN_REPO" ] && git -C "$MAIN_REPO" worktree remove --force "$WT" >/dev/null 2>&1
  [ -n "$WORK" ] && rm -rf "$WORK"
  # prune AFTER the worktree dir is gone so a partial registration from a failed
  # `worktree add` (WT may be "") is also reaped, not just a clean removal
  [ -n "$MAIN_REPO" ] && git -C "$MAIN_REPO" worktree prune >/dev/null 2>&1 || true
  [ -n "$STDIN_TMP" ] && rm -f "$STDIN_TMP"
  return 0
}
# On a signal, clean up and ABORT immediately so the script does not resume on
# torn-down directories; cleanup() is idempotent so the EXIT trap is harmless.
on_signal() { cleanup; trap - INT TERM EXIT; exit 130; }
trap cleanup EXIT
trap on_signal INT TERM

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
_pf_dir="$(cd "$(dirname "$PROMPT_FILE")" 2>/dev/null && pwd)" || die "cannot resolve prompt-file directory"
[ -n "$_pf_dir" ] || die "cannot resolve prompt-file directory"
PROMPT_FILE="$_pf_dir/$(basename "$PROMPT_FILE")"

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

WORK="$(mktemp -d)" || die "mktemp -d failed"
[ -n "$WORK" ] && [ -d "$WORK" ] || die "could not create work dir"

# ---- build the disposable review worktree (when inside a git work tree) ----
REVIEW_CWD="$PWD"
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  MAIN_REPO="$(git rev-parse --show-toplevel 2>/dev/null)"
  git worktree prune >/dev/null 2>&1 || true
  WT="$WORK/wt"
  # core.hooksPath=/dev/null: do not run the repo's post-checkout/post-commit
  # hooks (which are shared code that could touch real repo state)
  if git -c core.hooksPath=/dev/null worktree add --detach --quiet "$WT" HEAD 2>/dev/null; then
    RO_GUARDED=1
    # replay the user's uncommitted TRACKED changes into the copy for faithful
    # review context (untracked/ignored files are deliberately left out); surface
    # a signal if the replay fails so a stale-HEAD review is not silent
    if ! git diff --quiet HEAD 2>/dev/null; then
      if git diff --binary HEAD 2>/dev/null | git -C "$WT" apply --index --whitespace=nowarn 2>/dev/null; then
        WIP_REPLAYED="yes"
      else
        WIP_REPLAYED="failed"
        echo "ens-review: warning: could not replay uncommitted changes into the review copy; reviewers will see HEAD" >&2
      fi
    fi
    # commit the snapshot so the worktree has a CLEAN status baseline; any dirt
    # observed after the reviewers run is therefore a reviewer write
    git -C "$WT" add -A >/dev/null 2>&1 || true
    git -C "$WT" -c core.hooksPath=/dev/null -c user.email=ensemble@local -c user.name=ensemble \
      -c commit.gpgsign=false commit --quiet --no-verify --allow-empty -m ensemble-review-snapshot >/dev/null 2>&1 || true
    # ephemeral-artifact ignore list: a reviewer that *runs* the code legitimately
    # produces bytecode / tool caches (__pycache__, .pyc, .serena, .pytest_cache, ...)
    # which are NOT source edits. Pass it as a per-command core.excludesFile so git omits
    # these untracked artifacts from --porcelain; a tracked-file edit or a NEW non-ephemeral
    # file still trips the guard (the real tamper signal). Does not touch the user's repo.
    RO_IGNORE="$WORK/.ro-ignore"
    printf '%s\n' '__pycache__/' '*.py[cod]' '.serena/' '.pytest_cache/' '.mypy_cache/' \
      '.ruff_cache/' '.tox/' '.ipynb_checkpoints/' '.DS_Store' 'node_modules/' > "$RO_IGNORE"
    # capture the post-setup baseline; a reviewer write is any DELTA from it. This is
    # robust even if the snapshot commit failed (baseline would just be non-empty),
    # so a clean reviewer run never false-positives to exit 5.
    RO_BASELINE="$(git -C "$WT" -c core.excludesFile="$RO_IGNORE" status --porcelain 2>/dev/null)"
    REVIEW_CWD="$WT"
  else
    # isolation was expected (we are in a git repo) but could not be created:
    # fail closed rather than silently run reviewers against the user's tree
    WT=""
    die "could not create an isolated review worktree (git worktree add failed); refusing to run reviewers against your working tree"
  fi
else
  # not a git work tree: isolation is impossible; run unguarded but make it loud
  # (read_only_guarded:false also signals this in the JSON)
  echo "ens-review: note: not inside a git work tree -- reviewers run unguarded in $PWD" >&2
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
# violation = the worktree status CHANGED from the post-setup baseline
RO_VIOLATION=0
if [ "$RO_GUARDED" = 1 ]; then
  if [ "$(git -C "$WT" -c core.excludesFile="$RO_IGNORE" status --porcelain 2>/dev/null)" != "$RO_BASELINE" ]; then
    RO_VIOLATION=1
    git -C "$WT" -c core.excludesFile="$RO_IGNORE" status --porcelain -z 2>/dev/null > "$WORK/.mutated" || true
  fi
fi

ENS_RO_V="$RO_VIOLATION" ENS_RO_G="$RO_GUARDED" ENS_WIP="$WIP_REPLAYED" \
python3 - "$WORK" "$ROSTER" "${REVIEWERS[@]}" <<'PY'
import json,os,re,sys
from collections import defaultdict
work,roster=sys.argv[1],sys.argv[2]; eps=sys.argv[3:]
ro_v=os.environ.get("ENS_RO_V","0"); ro_g=os.environ.get("ENS_RO_G","0"); wip=os.environ.get("ENS_WIP","none")
try:
    rd=json.load(open(roster, encoding="utf-8"))
    if not isinstance(rd, dict): rd={}
except Exception:
    rd={}
fam={e["id"]:e.get("family") for e in (rd.get("endpoints") or []) if isinstance(e,dict) and e.get("id")}
REASON={2:"failed",3:"empty",10:"quota",11:"auth",12:"timeout",13:"missing",125:"isolation-failed"}
_ok=re.compile(r'^[A-Za-z0-9._@-]+$')
reviewers=[]
for ep in eps:
    # defense in depth; bash already validated, but never build a path from a bad id
    if (not _ok.match(ep)) or ep.startswith('-') or '..' in ep or os.sep in ep or ep in (".",".."):
        continue
    p=os.path.join(work,ep)
    rc=int(open(p+".rc").read().strip()) if os.path.exists(p+".rc") else 1
    rec={"endpoint":ep,"family":fam.get(ep),"status":"ok","reason":None,"verdict":None,"findings":[],"review":""}
    if rc==0:
        try:
            v=json.load(open(p+".out", encoding="utf-8"))
            rec["verdict"]=v.get("verdict"); rec["findings"]=v.get("findings") or []
            # surface the raw review prose (capped) so sentinel reviewers — which
            # carry detail in text, not a findings[] array — contribute to synthesis
            rec["review"]=(v.get("raw") or "")[:4000]
        except Exception:
            rec["status"]="degraded"; rec["reason"]="unparseable"
    else:
        rec["status"]="degraded"; rec["reason"]=REASON.get(rc,"failed")
    reviewers.append(rec)

mq=rd.get("min_quorum",2)
min_q = mq if (isinstance(mq,int) and not isinstance(mq,bool) and mq>=1) else 2
# cap so a config typo (e.g. 999) cannot make quorum permanently unreachable:
# you cannot require more distinct families than there are reviewers
if reviewers: min_q = min(min_q, len(reviewers))
ok = [r for r in reviewers if r["status"]=="ok"]
fams_ok=[]; seen=set()
for r in ok:
    f=r["family"]
    if f and f not in seen: seen.add(f); fams_ok.append(f)
# collisions: families with >1 ok reviewer
by=defaultdict(list)
for r in ok:
    if r["family"]: by[r["family"]].append(r["endpoint"])
collisions=[{"family":k,"endpoints":v} for k,v in by.items() if len(v)>1]
quorum_met = len(fams_ok) >= min_q
mutated=[]
mf=os.path.join(work,".mutated")
if os.path.exists(mf):
    raw=open(mf,encoding="utf-8",errors="replace").read()
    for rec in raw.split("\0"):
        if not rec: continue
        # porcelain -z records are "XY path"; a rename emits a second prefix-less
        # record (the source path) -- only strip when the "XY " prefix is present
        mutated.append(rec[3:] if (len(rec)>3 and rec[2]==" ") else rec)
res={"reviewers":reviewers,"families_ok":fams_ok,"family_collisions":collisions,
     "quorum_required":min_q,"quorum_met":quorum_met,
     "read_only_violation": ro_v=="1",
     "read_only_guarded": ro_g=="1",
     "wip_replayed": wip,
     "mutated_files": mutated}
print(json.dumps(res, indent=2))
if ro_v=="1": sys.exit(5)
sys.exit(0 if quorum_met else 4)
PY
exit $?
