#!/usr/bin/env bash
set -uo pipefail
ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
SCRIPTS="$ROOT/scripts"
ROSTER="${ENSEMBLE_ROSTER:-$ROOT/roster.json}"
die() { echo "ens-delegate: $*" >&2; exit 1; }

# ----------------------------------------------------------------------------
# Delegate engine (design spec §7): run a strength-routed EXECUTOR model in an
# isolated git worktree, then let the caller verify in a clean state and merge.
#   run     create a worktree on a fresh branch, run the executor (write mode) in
#           it, and emit {endpoint, signal, worktree, branch, files_changed,
#           diff_stat, digest}. The worktree is LEFT in place for verification.
#   merge   commit the executor's changes on its branch and merge into the current
#           branch, then remove the worktree.
#   discard remove the worktree and delete its branch (executor changes thrown away).
#
# SAFETY: the worktree is the containment boundary for the EXPECTED writes; codex
# runs OS-sandboxed (workspace-write) to that worktree, the other executors rely on
# cwd + auto-approve and could in principle write outside it (same residual as the
# review engine — documented). Trust boundary per §7.4 is the CALLER's clean-state
# re-verify; never trust the executor's self-reported success.
# ----------------------------------------------------------------------------

sub="${1:-}"; shift || true
case "$sub" in run|merge|discard) : ;; *) die "usage: ens-delegate.sh run|merge|discard ..." ;; esac
command -v git >/dev/null 2>&1 || die "git is required"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not inside a git work tree"
MAIN_REPO="$(git rev-parse --show-toplevel 2>/dev/null)" || die "cannot resolve repo root"

_wt_branch() { git -C "$1" rev-parse --abbrev-ref HEAD 2>/dev/null; }
_rm_tmp_parent() { # remove the mktemp parent of a worktree, only under known temp roots
  local p; p="$(dirname "$1")"
  case "$p" in /tmp/*|/var/folders/*|/private/var/folders/*|/private/tmp/*) rm -rf "$p" ;; esac
}

# ============================ run ============================
if [ "$sub" = "run" ]; then
  ENDPOINT=""; PROMPT_FILE=""; STDIN_TMP=""; BASE="HEAD"
  while [ $# -gt 0 ]; do
    case "$1" in
      --endpoint) ENDPOINT="$2"; shift 2 ;;
      --prompt-file) PROMPT_FILE="$2"; shift 2 ;;
      --base) BASE="$2"; shift 2 ;;
      -) PROMPT_FILE="$(mktemp)"; cat > "$PROMPT_FILE"; STDIN_TMP="$PROMPT_FILE"; shift ;;
      *) die "unknown arg '$1'" ;;
    esac
  done
  [ -n "$ENDPOINT" ] || die "need --endpoint"
  [ -n "$PROMPT_FILE" ] && [ -f "$PROMPT_FILE" ] || die "need --prompt-file or '-'"
  _pd="$(cd "$(dirname "$PROMPT_FILE")" 2>/dev/null && pwd)" || die "cannot resolve prompt-file dir"
  PROMPT_FILE="$_pd/$(basename "$PROMPT_FILE")"
  [[ "$ENDPOINT" =~ ^[A-Za-z0-9._@-]+$ ]] || die "invalid endpoint id '$ENDPOINT'"

  WORK="$(mktemp -d)" || die "mktemp -d failed"
  WT="$WORK/wt"
  BR="ensemble/delegate-$(basename "$WORK" | tr -cd 'A-Za-z0-9._-')"
  if ! git -C "$MAIN_REPO" worktree add --quiet -b "$BR" "$WT" "$BASE" 2>"$WORK/wterr"; then
    cat "$WORK/wterr" >&2; rm -rf "$WORK"; [ -n "$STDIN_TMP" ] && rm -f "$STDIN_TMP"
    die "could not create delegate worktree (base '$BASE')"
  fi

  DIGEST="$WORK/digest.txt"
  ENSEMBLE_ROSTER="$ROSTER" "$SCRIPTS/model-cli.sh" run \
    --endpoint "$ENDPOINT" --prompt-file "$PROMPT_FILE" --dir "$WT" >"$DIGEST" 2>"$WORK/err"; rc=$?
  [ -n "$STDIN_TMP" ] && rm -f "$STDIN_TMP"

  # emit a structured result; the worktree is LEFT in place for clean-state verify
  ENS_RC="$rc" python3 - "$WT" "$BR" "$DIGEST" "$WORK/err" "$ENDPOINT" <<'PY'
import json,os,sys,subprocess
wt,br,digestf,errf,ep=sys.argv[1:6]; rc=int(os.environ.get("ENS_RC","1"))
def sh(*a):
    try: return subprocess.run(a,capture_output=True,text=True,timeout=30).stdout
    except Exception: return ""
files=[l[3:] for l in sh("git","-C",wt,"status","--porcelain").splitlines() if l]
def read(p):
    try: return open(p,encoding="utf-8",errors="replace").read()
    except Exception: return ""
# intent-to-add so NEW files also appear in `diff --stat` (no content is staged, so
# the later merge's `git add -A` is unaffected)
sh("git","-C",wt,"add","-A","-N")
REASON={2:"failed",3:"empty",10:"quota",11:"auth",12:"timeout",13:"missing"}
print(json.dumps({"endpoint":ep,"status":"ok" if rc==0 else "failed",
    "signal":(REASON.get(rc,"failed") if rc else None),
    "worktree":wt,"branch":br,"files_changed":files,
    "diff_stat":sh("git","-C",wt,"diff","--stat").strip(),
    "digest":read(digestf),"stderr":(read(errf)[:2000] if rc else "")}, indent=2))
PY
  exit "$rc"
fi

# ============================ merge ============================
if [ "$sub" = "merge" ]; then
  WT=""; MSG=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --worktree) WT="$2"; shift 2 ;;
      --message) MSG="$2"; shift 2 ;;
      *) die "unknown arg '$1'" ;;
    esac
  done
  [ -n "$WT" ] && [ -d "$WT" ] || die "merge needs --worktree <path>"
  BR="$(_wt_branch "$WT")"; [ -n "$BR" ] || die "cannot determine the worktree's branch"
  [ -n "$MSG" ] || MSG="ensemble delegate: $BR"
  if [ -n "$(git -C "$WT" status --porcelain 2>/dev/null)" ]; then
    git -C "$WT" add -A || die "git add in worktree failed"
    git -C "$WT" -c core.hooksPath=/dev/null -c user.email=ensemble@local -c user.name=ensemble \
      commit --quiet -m "$MSG" || die "commit in worktree failed"
  fi
  git -C "$MAIN_REPO" merge --no-ff -m "$MSG" "$BR" \
    || die "merge of '$BR' failed (resolve in $MAIN_REPO, or discard --worktree '$WT')"
  git -C "$MAIN_REPO" worktree remove --force "$WT" >/dev/null 2>&1
  git -C "$MAIN_REPO" branch -D "$BR" >/dev/null 2>&1
  git -C "$MAIN_REPO" worktree prune >/dev/null 2>&1 || true
  _rm_tmp_parent "$WT"
  echo "merged $BR"
  exit 0
fi

# ============================ discard ============================
if [ "$sub" = "discard" ]; then
  WT=""
  while [ $# -gt 0 ]; do
    case "$1" in --worktree) WT="$2"; shift 2 ;; *) die "unknown arg '$1'" ;; esac
  done
  [ -n "$WT" ] || die "discard needs --worktree <path>"
  BR="$(_wt_branch "$WT" 2>/dev/null)"
  git -C "$MAIN_REPO" worktree remove --force "$WT" >/dev/null 2>&1
  [ -n "$BR" ] && git -C "$MAIN_REPO" branch -D "$BR" >/dev/null 2>&1
  git -C "$MAIN_REPO" worktree prune >/dev/null 2>&1 || true
  _rm_tmp_parent "$WT"
  echo "discarded ${BR:-worktree}"
  exit 0
fi
