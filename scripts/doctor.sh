#!/usr/bin/env bash
set -uo pipefail
ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
SCRIPTS="$ROOT/scripts"
source "$SCRIPTS/lib/roster-path.sh"   # resolves ROSTER (ENSEMBLE_ROSTER | CLAUDE_PLUGIN_DATA | shipped)
source "$SCRIPTS/lib/timeout.sh"; source "$SCRIPTS/lib/roster.sh"
[ -r "$ROSTER" ] || { echo "doctor: roster '$ROSTER' missing or unreadable" >&2; exit 1; }
if ! command -v timeout >/dev/null 2>&1 && ! command -v gtimeout >/dev/null 2>&1; then
  echo "  note: 'timeout'/'gtimeout' not found — using the perl/python fallback guard." >&2
  echo "        install GNU coreutils for the robust path (macOS: brew install coreutils)." >&2
fi
FAIL=0
echo "ensemble — doctor"
SEEN=0
HFAMS=""   # newline-separated families of HEALTHY reviewer endpoints (quorum is by family)
while IFS= read -r ep; do
  [ -n "$ep" ] || continue
  SEEN=1
  adapter="$(ens_endpoint_field "$ROSTER" "$ep" adapter)"
  [[ "$adapter" =~ ^[a-z0-9_-]+$ ]] || { echo "invalid adapter name '$adapter'" >&2; exit 1; }
  [ -f "$SCRIPTS/adapters/$adapter.sh" ] || { echo "no adapter '$adapter'" >&2; exit 1; }
  source "$SCRIPTS/adapters/$adapter.sh"
  declare -F "${adapter}_health" >/dev/null && declare -F "${adapter}_list_models" >/dev/null || { echo "  $ep: adapter '$adapter' missing required functions" >&2; FAIL=1; continue; }
  st="$("${adapter}_health")"
  if [ "$st" = "ok" ]; then
    n="$("${adapter}_list_models" | grep -c . || true)"
    printf '  %s: ok (%s models)\n' "$ep" "$n"
    role="$(ens_endpoint_field "$ROSTER" "$ep" role)"
    case "$role" in reviewer|both) fam="$(ens_family_of "$ROSTER" "$ep")"; [ -n "$fam" ] && HFAMS="$HFAMS$fam
" ;; esac
  else
    printf '  %s: %s\n' "$ep" "$st"; FAIL=1
  fi
done < <(ens_endpoints_enabled "$ROSTER")
[ "$SEEN" -eq 1 ] || { echo "doctor: no enabled endpoints in roster '$ROSTER'" >&2; exit 1; }

# family / quorum coverage — reviews need >= min_quorum DISTINCT healthy model families
NFAM="$(printf '%s' "$HFAMS" | sed '/^$/d' | sort -u | grep -c . | tr -d ' ')"
MINQ="$(python3 -c "import json; print(int((json.load(open('$ROSTER')).get('min_quorum') or 2)))" 2>/dev/null || echo 2)"
echo "Healthy reviewer families: ${NFAM} (min_quorum ${MINQ})."
[ "${NFAM:-0}" -lt "${MINQ:-2}" ] && echo "  warning: below min_quorum — reviews may not reach quorum; run /ensemble:setup to add families."

[ "$FAIL" -eq 0 ] && echo "All enabled endpoints healthy." || echo "Some endpoints need attention."
exit "$FAIL"
