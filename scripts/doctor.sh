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

# Health probes can FLAP: a slow/cold transport CLI intermittently returns an
# auth-looking error (or times out) even while genuinely authenticated — observed
# with agy/grok, whose `models` call can take 8-15s and occasionally answers
# "please sign in" on one call and lists models on the next. Treat a single
# non-ok verdict as inconclusive: retry up to ENS_DOCTOR_HEALTH_TRIES times and
# accept the first 'ok'. 'missing' is deterministic (command not found), so we
# never retry it. Tests set ENS_DOCTOR_RETRY_SLEEP=0 to keep the suite fast.
ENS_DOCTOR_HEALTH_TRIES="${ENS_DOCTOR_HEALTH_TRIES:-3}"
ENS_DOCTOR_RETRY_SLEEP="${ENS_DOCTOR_RETRY_SLEEP:-1}"
# Guard misconfiguration: a non-numeric or <1 value would skip the loop and yield
# an empty verdict (treated as a failure). Fall back to the default.
case "$ENS_DOCTOR_HEALTH_TRIES" in ''|*[!0-9]*) ENS_DOCTOR_HEALTH_TRIES=3 ;; esac
[ "$ENS_DOCTOR_HEALTH_TRIES" -ge 1 ] || ENS_DOCTOR_HEALTH_TRIES=3
ens_health_checked() { # ADAPTER EP -> ok|auth|missing  (echoes the final verdict)
  local adapter="$1" ep="$2" st i
  for (( i=1; i<=ENS_DOCTOR_HEALTH_TRIES; i++ )); do
    st="$("${adapter}_health")"
    [ "$st" = ok ] && { printf 'ok'; return 0; }
    [ "$st" = missing ] && { printf 'missing'; return 0; }
    if [ "$i" -lt "$ENS_DOCTOR_HEALTH_TRIES" ]; then
      printf '  %s: probe returned %s (attempt %d/%d) — retrying...\n' \
        "$ep" "$st" "$i" "$ENS_DOCTOR_HEALTH_TRIES" >&2
      [ "$ENS_DOCTOR_RETRY_SLEEP" = 0 ] || sleep "$ENS_DOCTOR_RETRY_SLEEP"
    fi
  done
  printf '%s' "$st"
}

echo "ensemble — doctor"
# Heads-up so a slow probe never reads as a hang: each probe attempt can take up to
# ~20s, and a non-ok verdict is retried up to ENS_DOCTOR_HEALTH_TRIES total attempts
# (flaps are common on cold CLIs). Always printed — even at tries=1 a single cold
# probe can take ~20s, and the per-endpoint breadcrumb below is the only other marker.
printf '  probing each endpoint (~20s per attempt, up to %d attempt(s); a down/cold CLI can take a while)\n' \
  "$ENS_DOCTOR_HEALTH_TRIES" >&2
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
  printf '  checking %s...\n' "$ep" >&2
  st="$(ens_health_checked "$adapter" "$ep")"
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
