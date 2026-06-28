#!/usr/bin/env bash
set -uo pipefail
ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
SCRIPTS="$ROOT/scripts"; ROSTER="${ENSEMBLE_ROSTER:-$ROOT/roster.json}"
source "$SCRIPTS/lib/timeout.sh"; source "$SCRIPTS/lib/roster.sh"
[ -r "$ROSTER" ] || { echo "doctor: roster '$ROSTER' missing or unreadable" >&2; exit 1; }
if ! command -v timeout >/dev/null 2>&1 && ! command -v gtimeout >/dev/null 2>&1; then
  echo "  note: 'timeout'/'gtimeout' not found — using the perl/python fallback guard." >&2
  echo "        install GNU coreutils for the robust path (macOS: brew install coreutils)." >&2
fi
FAIL=0
echo "multi-model-cc — doctor"
SEEN=0
while IFS= read -r ep; do
  [ -n "$ep" ] || continue
  SEEN=1
  adapter="$(ens_endpoint_field "$ROSTER" "$ep" adapter)"
  [[ "$adapter" =~ ^[a-z0-9_-]+$ ]] || { echo "invalid adapter name '$adapter'" >&2; exit 1; }
  [ -f "$SCRIPTS/adapters/$adapter.sh" ] || { echo "no adapter '$adapter'" >&2; exit 1; }
  source "$SCRIPTS/adapters/$adapter.sh"
  declare -F "${adapter}_health" >/dev/null || { echo "  $ep: adapter '$adapter' missing ${adapter}_health" >&2; FAIL=1; continue; }
  st="$("${adapter}_health")"
  if [ "$st" = "ok" ]; then
    n="$("${adapter}_list_models" | grep -c . || true)"
    printf '  %s: ok (%s models)\n' "$ep" "$n"
  else
    printf '  %s: %s\n' "$ep" "$st"; FAIL=1
  fi
done < <(ens_endpoints_enabled "$ROSTER")
[ "$SEEN" -eq 1 ] || { echo "doctor: no enabled endpoints in roster '$ROSTER'" >&2; exit 1; }
[ "$FAIL" -eq 0 ] && echo "All enabled endpoints healthy." || echo "Some endpoints need attention."
exit "$FAIL"
