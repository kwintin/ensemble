#!/usr/bin/env bash
set -uo pipefail
ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
SCRIPTS="$ROOT/scripts"
source "$SCRIPTS/lib/roster-path.sh"   # resolves ROSTER (ENSEMBLE_ROSTER | CLAUDE_PLUGIN_DATA | shipped)
source "$SCRIPTS/lib/timeout.sh"
source "$SCRIPTS/lib/signal.sh"
source "$SCRIPTS/lib/roster.sh"
source "$SCRIPTS/lib/verdict.sh"
source "$SCRIPTS/lib/adapter_common.sh"

# exit 1 = usage error (outside the 0/2/3/10-13 runtime contract)
die() { echo "model-cli: $*" >&2; exit 1; }

# ISOLATION BOUNDARY: this dispatcher runs the adapter in the CURRENT directory and
# does NOT provide isolation. The safe entry points are ens-review.sh (reviewers in
# a disposable worktree) and ens-delegate.sh (executors in an isolated worktree).
# Invoking model-cli directly with a directive-only adapter (no native read-only/OS
# sandbox) in a real repo lets a disobeying model write the tree. `run` requires an
# existing --dir and runs the executor there. Direct use is for the engines or
# trusted/scratch contexts only.

# Map a non-zero adapter exit to the structured runtime contract, then exit.
map_failure() { # RC ERRFILE ENDPOINT
  local rc="$1" ef="$2" ep="$3" code
  [ "$rc" -eq 124 ] && { ens_signal TIMEOUT "wall-clock guard" "$ep"; exit 12; }
  [ "$rc" -eq 127 ] && { ens_signal MISSING "executable not found" "$ep"; exit 13; }
  [ "$rc" -eq 125 ] && { ens_signal FAILED "fork failed" "$ep"; exit 2; }
  if [ "$rc" -ne 0 ]; then code="$(ens_classify "$rc" "$ef" "$ep")"; exit "${code:-2}"; fi
}

verb="${1:-}"; shift || true
case "$verb" in review|run) : ;; *) die "verb must be 'review' or 'run'" ;; esac

ENDPOINT=""; PROMPT_FILE=""; STDIN_TMP=""; DIR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --endpoint) ENDPOINT="$2"; shift 2 ;;
    --prompt-file) PROMPT_FILE="$2"; shift 2 ;;
    --dir) DIR="$2"; shift 2 ;;
    -) PROMPT_FILE="$(mktemp)"; cat > "$PROMPT_FILE"; STDIN_TMP="$PROMPT_FILE"; shift ;;
    *) die "unknown arg '$1'" ;;
  esac
done
[ -n "$ENDPOINT" ] || die "need --endpoint"
[ -n "$PROMPT_FILE" ] || die "need --prompt-file or '-'"
[ "$PROMPT_FILE" = "-" ] || [ -f "$PROMPT_FILE" ] || die "prompt file not found: $PROMPT_FILE"

[ -r "$ROSTER" ] || die "roster '$ROSTER' missing or unreadable"
ADAPTER="$(ens_endpoint_field "$ROSTER" "$ENDPOINT" adapter)"
MODEL="$(ens_endpoint_field "$ROSTER" "$ENDPOINT" model)"
EFFORT="$(ens_endpoint_field "$ROSTER" "$ENDPOINT" effort)"
STRUCT="$(ens_endpoint_field "$ROSTER" "$ENDPOINT" structured_output)"
ROLE="$(ens_endpoint_field "$ROSTER" "$ENDPOINT" role)"
[ -n "$ADAPTER" ] || die "unknown endpoint '$ENDPOINT'"
# model ids vary by transport: bare (gpt-5.5), slashed (opencode-go/deepseek-v4-pro,
# kilo/z-ai/glm-5.2), or spaced display names (Gemini 3.5 Flash (Medium)). The model
# is only ever passed as a single quoted argv element to the CLI (never re-parsed by a
# shell, never used as a path), so this is a typo/sanity guard, not a security boundary.
[[ "$MODEL" =~ ^[A-Za-z0-9\ ()._/+-]+$ ]] || die "invalid model '$MODEL'"
[[ "$EFFORT" =~ ^(minimal|low|medium|high|xhigh)$ ]] || die "invalid effort '$EFFORT'"
[[ "$ADAPTER" =~ ^[a-z0-9_-]+$ ]] || die "invalid adapter name '$ADAPTER'"
[ -f "$SCRIPTS/adapters/$ADAPTER.sh" ] || die "no adapter '$ADAPTER'"
source "$SCRIPTS/adapters/$ADAPTER.sh"

OUT="$(mktemp)"; ERR="$(mktemp)"
trap 'rm -f "$OUT" "$ERR" "$STDIN_TMP"' EXIT

if [ "$verb" = "review" ]; then
  [[ "$STRUCT" =~ ^(json|sentinel)$ ]] || die "invalid structured_output '$STRUCT'"
  declare -F "${ADAPTER}_review" >/dev/null || die "adapter '$ADAPTER' has no ${ADAPTER}_review"
  "${ADAPTER}_review" "$ENDPOINT" "$MODEL" "$EFFORT" "$PROMPT_FILE" "$OUT" 2>"$ERR"; rc=$?
  map_failure "$rc" "$ERR" "$ENDPOINT"
  [ -s "$OUT" ] || { echo "model-cli: empty output" >&2; exit 3; }
  MODE="json"; [ "$STRUCT" = "sentinel" ] && MODE="sentinel"
  NORM="$(ens_normalize_verdict "$ENDPOINT" "$MODE" "$OUT")"
  printf '%s\n' "$NORM"
  printf '%s' "$NORM" | python3 -c 'import sys,json; sys.exit(0 if json.load(sys.stdin).get("verdict")=="ERROR" else 1)' && exit 3
  exit 0
else  # run (executor)
  [ -n "$DIR" ] || die "run needs --dir <existing directory>"
  [ -d "$DIR" ] || die "run --dir '$DIR' is not a directory"
  [[ "$ROLE" =~ ^(executor|both)$ ]] || die "endpoint '$ENDPOINT' has role '$ROLE' (not executor-capable)"
  declare -F "${ADAPTER}_run" >/dev/null || die "adapter '$ADAPTER' is not executor-capable (no ${ADAPTER}_run)"
  "${ADAPTER}_run" "$ENDPOINT" "$MODEL" "$EFFORT" "$PROMPT_FILE" "$DIR" "$OUT" 2>"$ERR"; rc=$?
  map_failure "$rc" "$ERR" "$ENDPOINT"
  [ -s "$OUT" ] || { echo "model-cli: empty output (executor produced no digest)" >&2; exit 3; }
  cat "$OUT"   # raw executor output, including the ===DIGEST=== trailer
  exit 0
fi
