#!/usr/bin/env bash
set -uo pipefail
ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
SCRIPTS="$ROOT/scripts"; ROSTER="${ENSEMBLE_ROSTER:-$ROOT/roster.json}"
source "$SCRIPTS/lib/timeout.sh"; source "$SCRIPTS/lib/roster.sh"
FAIL=0
echo "multi-model-cc — doctor"
while IFS= read -r ep; do
  [ -n "$ep" ] || continue
  adapter="$(ens_endpoint_field "$ROSTER" "$ep" adapter)"
  source "$SCRIPTS/adapters/$adapter.sh"
  st="$("${adapter}_health")"
  if [ "$st" = "ok" ]; then
    n="$("${adapter}_list_models" | grep -c . || true)"
    printf '  %s: ok (%s models)\n' "$ep" "$n"
  else
    printf '  %s: %s\n' "$ep" "$st"; FAIL=1
  fi
done < <(ens_endpoints_enabled "$ROSTER")
[ "$FAIL" -eq 0 ] && echo "All enabled endpoints healthy." || echo "Some endpoints need attention."
exit "$FAIL"
