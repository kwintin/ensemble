#!/usr/bin/env bash
# SessionStart hook (design spec §8): inject the three-gate policy + a one-line
# summary of which reviewers are configured. A NUDGE, never a mandate. Togglable
# with ENSEMBLE_GATE_REMINDERS=0. Must be fast (reads the roster, no network) and
# must never break session start (always exits 0).
set -uo pipefail
ROOT="${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}}"
SCRIPTS="$ROOT/scripts"
cat >/dev/null 2>&1 || true   # consume the hook's stdin JSON (unused)

_t="$(printf '%s' "${ENSEMBLE_GATE_REMINDERS:-1}" | tr '[:upper:]' '[:lower:]')"
case "$_t" in 0|off|false|no|disabled) exit 0 ;; esac

source "$SCRIPTS/lib/roster-path.sh" 2>/dev/null || true
source "$SCRIPTS/lib/roster.sh" 2>/dev/null || true

revs="(none configured — run the Ensemble setup workflow)"; fams=0
if [ -n "${ROSTER:-}" ] && [ -r "$ROSTER" ]; then
  _r="$(ens_reviewers "$ROSTER" 2>/dev/null | paste -sd, - 2>/dev/null)"
  [ -n "$_r" ] && revs="$_r"
  fams="$(python3 - "$ROSTER" <<'PY' 2>/dev/null || echo 0
import json,sys
try: d=json.load(open(sys.argv[1],encoding="utf-8"))
except Exception: print(0); sys.exit()
fs={e.get("family") for e in (d.get("endpoints") or [])
    if isinstance(e,dict) and e.get("enabled") and e.get("role") in ("reviewer","both") and e.get("family")}
print(len(fs))
PY
)"
fi

ctx="Ensemble multi-model review is available. Consider the Ensemble review workflow at three gates: (1) after writing a SPEC/design, (2) after writing a PLAN, (3) after IMPLEMENTATION / before merge. Invoke it with /ensemble:review in Claude Code or \$ensemble:multi-model-review in Codex; request council mode for high-stakes specs. To offload a scoped implementation unit to a strength-matched model, use the Ensemble delegation workflow (/ensemble:delegate in Claude Code or \$ensemble:delegate-implementation in Codex). Configured reviewer families: ${fams:-0}; reviewers: ${revs}. Use the Ensemble doctor workflow for live health and the setup workflow to reconfigure. (Nudges only — disable with ENSEMBLE_GATE_REMINDERS=0.)"

python3 - "$ctx" <<'PY' 2>/dev/null || true
import json,sys
print(json.dumps({"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":sys.argv[1]}}))
PY
exit 0
