#!/usr/bin/env bash
set -uo pipefail
ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
SCRIPTS="$ROOT/scripts"
ROSTER="${ENSEMBLE_ROSTER:-$ROOT/roster.json}"
source "$SCRIPTS/lib/timeout.sh"
source "$SCRIPTS/lib/signal.sh"
source "$SCRIPTS/lib/roster.sh"
source "$SCRIPTS/lib/verdict.sh"

# exit 1 = usage error (outside the 0/2/3/10-13 runtime contract)
die() { echo "model-cli: $*" >&2; exit 1; }

verb="${1:-}"; shift || true
[ "$verb" = "review" ] || die "only 'review' is implemented in this slice"

ENDPOINT=""; PROMPT_FILE=""; STDIN_TMP=""
while [ $# -gt 0 ]; do
  case "$1" in
    --endpoint) ENDPOINT="$2"; shift 2 ;;
    --prompt-file) PROMPT_FILE="$2"; shift 2 ;;
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
[ -n "$ADAPTER" ] || die "unknown endpoint '$ENDPOINT'"
[[ "$MODEL"  =~ ^[A-Za-z0-9._-]+$ ]] || die "invalid model '$MODEL'"
[[ "$EFFORT" =~ ^(minimal|low|medium|high|xhigh)$ ]] || die "invalid effort '$EFFORT'"
[[ "$STRUCT" =~ ^(json|sentinel)$ ]] || die "invalid structured_output '$STRUCT'"
[[ "$ADAPTER" =~ ^[a-z0-9_-]+$ ]] || die "invalid adapter name '$ADAPTER'"
[ -f "$SCRIPTS/adapters/$ADAPTER.sh" ] || die "no adapter '$ADAPTER'"
source "$SCRIPTS/adapters/$ADAPTER.sh"
declare -F "${ADAPTER}_review" >/dev/null || die "adapter '$ADAPTER' has no ${ADAPTER}_review"

OUT="$(mktemp)"; ERR="$(mktemp)"
trap 'rm -f "$OUT" "$ERR" "$STDIN_TMP"' EXIT
"${ADAPTER}_review" "$ENDPOINT" "$MODEL" "$EFFORT" "$PROMPT_FILE" "$OUT" 2>"$ERR"; rc=$?

if [ "$rc" -eq 124 ]; then ens_signal TIMEOUT "wall-clock guard" "$ENDPOINT"; exit 12; fi
if [ "$rc" -eq 127 ]; then ens_signal MISSING "executable not found" "$ENDPOINT"; exit 13; fi
if [ "$rc" -eq 125 ]; then ens_signal FAILED "fork failed" "$ENDPOINT"; exit 2; fi
if [ "$rc" -ne 0 ]; then code="$(ens_classify "$rc" "$ERR" "$ENDPOINT")"; exit "${code:-2}"; fi
if [ ! -s "$OUT" ]; then echo "model-cli: empty output" >&2; exit 3; fi

MODE="json"; [ "$STRUCT" = "sentinel" ] && MODE="sentinel"
NORM="$(ens_normalize_verdict "$ENDPOINT" "$MODE" "$OUT")"
printf '%s\n' "$NORM"
printf '%s' "$NORM" | python3 -c 'import sys,json; sys.exit(0 if json.load(sys.stdin).get("verdict")=="ERROR" else 1)' && exit 3
exit 0
